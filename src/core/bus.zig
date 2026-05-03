//! 4 KB unified RAM. ROMs load at 0x200; the built-in fontset lives at
//! 0x050–0x09F; 0x000–0x04F is left zero (reserved by the original
//! interpreter for its own scratch). The storage array is touched only by
//! Bus methods (CI grep enforced) so the 12-bit masking invariant lives in
//! the type, not in convention. Game Boy MBC bank-select, MMIO routing,
//! and OAM access gating depend on this seam being structural, per
//! `docs/next-target-handoff.md` bullet 16.

const std = @import("std");

pub const RAM_SIZE: usize = 4096;
pub const ROM_LOAD_ADDRESS: u16 = 0x200;
pub const FONTSET_ADDRESS: u16 = 0x050;
pub const FONT_GLYPH_BYTES: u16 = 5;
pub const ROM_MAX_BYTES: usize = RAM_SIZE - ROM_LOAD_ADDRESS;

const FONTSET = [_]u8{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

pub const Bus = struct {
    ram: [RAM_SIZE]u8,

    pub fn init() Bus {
        var bus = Bus{ .ram = [_]u8{0} ** RAM_SIZE };
        @memcpy(bus.ram[FONTSET_ADDRESS .. FONTSET_ADDRESS + FONTSET.len], &FONTSET);
        return bus;
    }

    pub fn read8(self: *const Bus, addr: u16) u8 {
        return self.ram[addr & 0x0FFF];
    }

    pub fn write8(self: *Bus, addr: u16, val: u8) void {
        self.ram[addr & 0x0FFF] = val;
    }

    pub fn read16(self: *const Bus, addr: u16) u16 {
        // The second byte mask wraps at the 4 KB boundary. A legal CHIP-8 PC
        // never reaches 0xFFF — programs live below 0xFFE since instructions
        // are two bytes — so this only triggers on a malformed ROM that sets
        // PC out of range, and we prefer "wrap quietly" over "panic the host"
        // (rule 12 in CLAUDE.md).
        const masked = addr & 0x0FFF;
        return (@as(u16, self.ram[masked]) << 8) | self.ram[(masked +% 1) & 0x0FFF];
    }

    /// Bulk-load ROM bytes at ROM_LOAD_ADDRESS. Caller is responsible for
    /// validating the slice fits (`rom.validate`).
    pub fn loadRom(self: *Bus, bytes: []const u8) void {
        @memcpy(self.ram[ROM_LOAD_ADDRESS .. ROM_LOAD_ADDRESS + bytes.len], bytes);
    }

    /// Bulk-write at the given address (test-only setup path). `addr` is a
    /// `u12` so out-of-range starting addresses are rejected at compile time
    /// rather than masked at runtime; caller must keep `addr + bytes.len`
    /// within `RAM_SIZE` (Zig slice bounds check otherwise panics).
    pub fn pokeSlice(self: *Bus, addr: u12, bytes: []const u8) void {
        @memcpy(self.ram[addr .. addr + bytes.len], bytes);
    }

    /// Bulk-read at the given address (test-only inspection path). Same
    /// `u12`-typed bounds contract as `pokeSlice`.
    pub fn peekSlice(self: *const Bus, addr: u12, len: usize) []const u8 {
        return self.ram[addr .. addr + len];
    }

    /// Writes the full 4 KB RAM image. Save-state framing (ordering, magic,
    /// version) is owned by `Machine.serialize`; this method only emits Bus
    /// bytes.
    pub fn serialize(self: *const Bus, writer: anytype) !void {
        try writer.writeAll(&self.ram);
    }

    /// Reads a 4 KB RAM image written by `serialize`. Caller positions the
    /// reader to the Bus chunk; this method consumes exactly `RAM_SIZE`
    /// bytes.
    pub fn deserialize(reader: anytype) !Bus {
        var bus: Bus = undefined;
        try reader.readSliceAll(&bus.ram);
        return bus;
    }
};

test "Bus.init zeroes RAM and seats the fontset at 0x050" {
    const bus = Bus.init();

    try std.testing.expectEqual(@as(u8, 0), bus.read8(0x000));
    try std.testing.expectEqual(@as(u8, 0), bus.read8(0x04F));
    try std.testing.expectEqual(@as(u8, 0xF0), bus.read8(0x050)); // first byte of '0' glyph
    try std.testing.expectEqual(@as(u8, 0x80), bus.read8(0x050 + 79)); // last byte of 'F' glyph
    try std.testing.expectEqual(@as(u8, 0), bus.read8(ROM_LOAD_ADDRESS));
}

test "Bus.loadRom places bytes starting at ROM_LOAD_ADDRESS" {
    var bus = Bus.init();
    const rom = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    bus.loadRom(&rom);

    try std.testing.expectEqualSlices(u8, &rom, bus.peekSlice(ROM_LOAD_ADDRESS, rom.len));
    // Fontset region untouched.
    try std.testing.expectEqual(@as(u8, 0xF0), bus.read8(0x050));
    // Pre-ROM region untouched.
    try std.testing.expectEqual(@as(u8, 0), bus.read8(0x1FF));
}

test "Bus.pokeSlice writes bytes at the given address" {
    var bus = Bus.init();
    const sprite = [_]u8{ 0xF0, 0x90, 0x90, 0x90, 0xF0 };

    bus.pokeSlice(0x300, &sprite);

    try std.testing.expectEqualSlices(u8, &sprite, bus.peekSlice(0x300, sprite.len));
}

test "Bus codec: round-trip preserves all 4096 bytes (fontset + ROM region)" {
    var src = Bus.init();
    const rom = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    src.loadRom(&rom);
    src.write8(0x1FF, 0x42);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.serialize(&aw.writer);
    try std.testing.expectEqual(@as(usize, RAM_SIZE), aw.written().len);

    var reader = std.Io.Reader.fixed(aw.written());
    const dst = try Bus.deserialize(&reader);

    try std.testing.expectEqualSlices(u8, src.peekSlice(0, RAM_SIZE), dst.peekSlice(0, RAM_SIZE));
    try std.testing.expectEqual(@as(u8, 0x42), dst.read8(0x1FF));
    try std.testing.expectEqualSlices(u8, &rom, dst.peekSlice(ROM_LOAD_ADDRESS, rom.len));
}
