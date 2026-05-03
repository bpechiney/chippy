//! Tier 1 debug affordance: opcode disassembly. Pure function so it's safe
//! to call from any context (trace formatting, debugger UI, test failure
//! messages). Cases get filled in as opcodes ship; everything else still
//! lands on `.unknown`.

const std = @import("std");

pub const DisasmEntry = struct {
    mnemonic: []const u8,
    nnn: u16 = 0,
    x: u4 = 0,
    nn: u8 = 0,

    pub const unknown = DisasmEntry{ .mnemonic = "???" };
};

pub fn disasm(opcode: u16) DisasmEntry {
    return switch (opcode & 0xF000) {
        0x0000 => switch (opcode) {
            0x00E0 => .{ .mnemonic = "CLS" },
            else => .{ .mnemonic = "SYS NNN", .nnn = opcode & 0x0FFF },
        },
        0x1000 => .{ .mnemonic = "JP NNN", .nnn = opcode & 0x0FFF },
        0x6000 => .{
            .mnemonic = "LD VX, NN",
            .x = @intCast((opcode & 0x0F00) >> 8),
            .nn = @truncate(opcode & 0x00FF),
        },
        0x7000 => .{
            .mnemonic = "ADD VX, NN",
            .x = @intCast((opcode & 0x0F00) >> 8),
            .nn = @truncate(opcode & 0x00FF),
        },
        0xA000 => .{ .mnemonic = "LD I, NNN", .nnn = opcode & 0x0FFF },
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

test "disasm(0x1456) returns JP NNN with nnn populated" {
    const e = disasm(0x1456);
    try std.testing.expectEqualStrings("JP NNN", e.mnemonic);
    try std.testing.expectEqual(@as(u16, 0x456), e.nnn);
}

test "disasm(0x6A42) returns LD VX, NN with x and nn populated" {
    const e = disasm(0x6A42);
    try std.testing.expectEqualStrings("LD VX, NN", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0xA), e.x);
    try std.testing.expectEqual(@as(u8, 0x42), e.nn);
}

test "disasm(0x7505) returns ADD VX, NN with x and nn populated" {
    const e = disasm(0x7505);
    try std.testing.expectEqualStrings("ADD VX, NN", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x5), e.x);
    try std.testing.expectEqual(@as(u8, 0x05), e.nn);
}

test "disasm(0xA789) returns LD I, NNN with nnn populated" {
    const e = disasm(0xA789);
    try std.testing.expectEqualStrings("LD I, NNN", e.mnemonic);
    try std.testing.expectEqual(@as(u16, 0x789), e.nnn);
}

test "disasm(0xFFFF) still returns the unknown sentinel" {
    const e = disasm(0xFFFF);
    try std.testing.expectEqualStrings("???", e.mnemonic);
}
