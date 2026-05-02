//! 4 KB unified RAM. ROMs load at 0x200; the built-in fontset lives at
//! 0x050–0x09F; 0x000–0x04F is left zero (reserved by the original
//! interpreter for its own scratch). Addresses are masked to 12 bits so a
//! buggy ROM can never panic the host (rule 12 in CLAUDE.md).

pub const RAM_SIZE: usize = 4096;
pub const ROM_LOAD_ADDRESS: u16 = 0x200;
pub const FONTSET_ADDRESS: u16 = 0x050;
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
};
