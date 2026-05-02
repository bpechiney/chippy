//! General-purpose CPU state: 16 V registers, the I address register, the
//! program counter, the stack pointer, and the 16-entry return stack.
//! Defaults match a freshly powered-on CHIP-8: PC at the ROM load address,
//! everything else zero.

const ROM_LOAD_ADDRESS: u16 = 0x200;

pub const Cpu = struct {
    v: [16]u8 = [_]u8{0} ** 16,
    i: u16 = 0,
    pc: u16 = ROM_LOAD_ADDRESS,
    sp: u8 = 0,
    stack: [16]u16 = [_]u16{0} ** 16,
};
