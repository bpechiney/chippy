//! Tier 1 debug affordance: opcode disassembly. Pure function so it's safe
//! to call from any context (trace formatting, debugger UI, test failure
//! messages). Cases get filled in as opcodes ship; everything else still
//! lands on `.unknown`.

const std = @import("std");
const decode = @import("decode.zig");

pub const DisasmEntry = struct {
    mnemonic: []const u8,
    nnn: u16 = 0,
    nn: u8 = 0,
    x: u4 = 0,
    y: u4 = 0,
    n: u4 = 0,

    pub const unknown = DisasmEntry{ .mnemonic = "???" };
};

pub fn disasm(opcode: u16) DisasmEntry {
    return switch (opcode & 0xF000) {
        0x0000 => switch (opcode) {
            0x00E0 => .{ .mnemonic = "CLS" },
            0x00EE => .{ .mnemonic = "RET" },
            else => .{ .mnemonic = "SYS NNN", .nnn = decode.opNNN(opcode) },
        },
        0x1000 => .{ .mnemonic = "JP NNN", .nnn = decode.opNNN(opcode) },
        0x2000 => .{ .mnemonic = "CALL NNN", .nnn = decode.opNNN(opcode) },
        0x3000 => .{
            .mnemonic = "SE VX, NN",
            .x = decode.opX(opcode),
            .nn = decode.opNN(opcode),
        },
        0x4000 => .{
            .mnemonic = "SNE VX, NN",
            .x = decode.opX(opcode),
            .nn = decode.opNN(opcode),
        },
        0x5000 => switch (decode.opN(opcode)) {
            0x0 => .{
                .mnemonic = "SE VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            else => DisasmEntry.unknown,
        },
        0x6000 => .{
            .mnemonic = "LD VX, NN",
            .x = decode.opX(opcode),
            .nn = decode.opNN(opcode),
        },
        0x7000 => .{
            .mnemonic = "ADD VX, NN",
            .x = decode.opX(opcode),
            .nn = decode.opNN(opcode),
        },
        0x8000 => switch (decode.opN(opcode)) {
            0x0 => .{
                .mnemonic = "LD VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            0x1 => .{
                .mnemonic = "OR VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            0x2 => .{
                .mnemonic = "AND VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            0x3 => .{
                .mnemonic = "XOR VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            0x4 => .{
                .mnemonic = "ADD VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            0x5 => .{
                .mnemonic = "SUB VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            0x6 => .{
                .mnemonic = "SHR VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            0x7 => .{
                .mnemonic = "SUBN VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            0xE => .{
                .mnemonic = "SHL VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            else => DisasmEntry.unknown,
        },
        0x9000 => switch (decode.opN(opcode)) {
            0x0 => .{
                .mnemonic = "SNE VX, VY",
                .x = decode.opX(opcode),
                .y = decode.opY(opcode),
            },
            else => DisasmEntry.unknown,
        },
        0xA000 => .{ .mnemonic = "LD I, NNN", .nnn = decode.opNNN(opcode) },
        0xB000 => .{ .mnemonic = "JP V0, NNN", .nnn = decode.opNNN(opcode) },
        0xC000 => .{
            .mnemonic = "RND VX, NN",
            .x = decode.opX(opcode),
            .nn = decode.opNN(opcode),
        },
        0xD000 => .{
            .mnemonic = "DRW VX, VY, N",
            .x = decode.opX(opcode),
            .y = decode.opY(opcode),
            .n = decode.opN(opcode),
        },
        0xF000 => switch (decode.opNN(opcode)) {
            0x07 => .{ .mnemonic = "LD VX, DT", .x = decode.opX(opcode) },
            0x15 => .{ .mnemonic = "LD DT, VX", .x = decode.opX(opcode) },
            0x1E => .{ .mnemonic = "ADD I, VX", .x = decode.opX(opcode) },
            0x29 => .{ .mnemonic = "LD F, VX", .x = decode.opX(opcode) },
            else => DisasmEntry.unknown,
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

test "disasm(0xD123) returns DRW VX, VY, N with x, y, n populated" {
    const e = disasm(0xD123);
    try std.testing.expectEqualStrings("DRW VX, VY, N", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x1), e.x);
    try std.testing.expectEqual(@as(u4, 0x2), e.y);
    try std.testing.expectEqual(@as(u4, 0x3), e.n);
}

test "disasm(0x00EE) returns RET" {
    const e = disasm(0x00EE);
    try std.testing.expectEqualStrings("RET", e.mnemonic);
}

test "disasm(0x2456) returns CALL NNN with nnn populated" {
    const e = disasm(0x2456);
    try std.testing.expectEqualStrings("CALL NNN", e.mnemonic);
    try std.testing.expectEqual(@as(u16, 0x456), e.nnn);
}

test "disasm(0x3542) returns SE VX, NN with x and nn populated" {
    const e = disasm(0x3542);
    try std.testing.expectEqualStrings("SE VX, NN", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x5), e.x);
    try std.testing.expectEqual(@as(u8, 0x42), e.nn);
}

test "disasm(0x4542) returns SNE VX, NN with x and nn populated" {
    const e = disasm(0x4542);
    try std.testing.expectEqualStrings("SNE VX, NN", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x5), e.x);
    try std.testing.expectEqual(@as(u8, 0x42), e.nn);
}

test "disasm(0x53A0) returns SE VX, VY with x and y populated" {
    const e = disasm(0x53A0);
    try std.testing.expectEqualStrings("SE VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83A0) returns LD VX, VY with x and y populated" {
    const e = disasm(0x83A0);
    try std.testing.expectEqualStrings("LD VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83A1) returns OR VX, VY with x and y populated" {
    const e = disasm(0x83A1);
    try std.testing.expectEqualStrings("OR VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83A2) returns AND VX, VY with x and y populated" {
    const e = disasm(0x83A2);
    try std.testing.expectEqualStrings("AND VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83A3) returns XOR VX, VY with x and y populated" {
    const e = disasm(0x83A3);
    try std.testing.expectEqualStrings("XOR VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83A4) returns ADD VX, VY with x and y populated" {
    const e = disasm(0x83A4);
    try std.testing.expectEqualStrings("ADD VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83A5) returns SUB VX, VY with x and y populated" {
    const e = disasm(0x83A5);
    try std.testing.expectEqualStrings("SUB VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83A7) returns SUBN VX, VY with x and y populated" {
    const e = disasm(0x83A7);
    try std.testing.expectEqualStrings("SUBN VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83A6) returns SHR VX, VY with x and y populated" {
    const e = disasm(0x83A6);
    try std.testing.expectEqualStrings("SHR VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83AE) returns SHL VX, VY with x and y populated" {
    const e = disasm(0x83AE);
    try std.testing.expectEqualStrings("SHL VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0x83A8) returns the unknown sentinel for non-canonical 8XYN low nibble" {
    const e = disasm(0x83A8);
    try std.testing.expectEqualStrings("???", e.mnemonic);
}

test "disasm(0x93A0) returns SNE VX, VY with x and y populated" {
    const e = disasm(0x93A0);
    try std.testing.expectEqualStrings("SNE VX, VY", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
    try std.testing.expectEqual(@as(u4, 0xA), e.y);
}

test "disasm(0xB456) returns JP V0, NNN with nnn populated" {
    const e = disasm(0xB456);
    try std.testing.expectEqualStrings("JP V0, NNN", e.mnemonic);
    try std.testing.expectEqual(@as(u16, 0x456), e.nnn);
}

test "disasm(0xC5AB) returns RND VX, NN with x and nn populated" {
    const e = disasm(0xC5AB);
    try std.testing.expectEqualStrings("RND VX, NN", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x5), e.x);
    try std.testing.expectEqual(@as(u8, 0xAB), e.nn);
}

test "disasm(0xF307) returns LD VX, DT with x populated" {
    const e = disasm(0xF307);
    try std.testing.expectEqualStrings("LD VX, DT", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
}

test "disasm(0xF315) returns LD DT, VX with x populated" {
    const e = disasm(0xF315);
    try std.testing.expectEqualStrings("LD DT, VX", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
}

test "disasm(0xF31E) returns ADD I, VX with x populated" {
    const e = disasm(0xF31E);
    try std.testing.expectEqualStrings("ADD I, VX", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
}

test "disasm(0xF329) returns LD F, VX with x populated" {
    const e = disasm(0xF329);
    try std.testing.expectEqualStrings("LD F, VX", e.mnemonic);
    try std.testing.expectEqual(@as(u4, 0x3), e.x);
}

test "disasm(0xF318) returns the unknown sentinel (FX18 lands in M5)" {
    const e = disasm(0xF318);
    try std.testing.expectEqualStrings("???", e.mnemonic);
}

test "disasm(0xFFFF) still returns the unknown sentinel" {
    const e = disasm(0xFFFF);
    try std.testing.expectEqualStrings("???", e.mnemonic);
}
