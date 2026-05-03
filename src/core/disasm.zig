//! Tier 1 debug affordance: opcode disassembly. Pure function so it's safe
//! to call from any context (trace formatting, debugger UI, test failure
//! messages). Cases get filled in as opcodes ship; everything else still
//! lands on `.unknown`.

const std = @import("std");

pub const DisasmEntry = struct {
    mnemonic: []const u8,
    nnn: u16 = 0,

    pub const unknown = DisasmEntry{ .mnemonic = "???" };
};

pub fn disasm(opcode: u16) DisasmEntry {
    return switch (opcode & 0xF000) {
        0x0000 => switch (opcode) {
            0x00E0 => .{ .mnemonic = "CLS" },
            else => .{ .mnemonic = "SYS NNN", .nnn = opcode & 0x0FFF },
        },
        else => DisasmEntry.unknown,
    };
}

test "disasm(0x00E0) returns CLS" {
    const e = disasm(0x00E0);
    try std.testing.expectEqualStrings("CLS", e.mnemonic);
}

test "disasm(0x0123) returns SYS NNN with nnn populated" {
    const e = disasm(0x0123);
    try std.testing.expectEqualStrings("SYS NNN", e.mnemonic);
    try std.testing.expectEqual(@as(u16, 0x123), e.nnn);
}

test "disasm(0xFFFF) still returns the unknown sentinel" {
    const e = disasm(0xFFFF);
    try std.testing.expectEqualStrings("???", e.mnemonic);
}
