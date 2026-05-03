//! Return types are narrowed to the field's natural width so call sites can
//! index `[16]u8` register banks and assign to `u8` immediates without the
//! ceremony of a per-site `@intCast` / `@truncate`.

const std = @import("std");

pub fn opX(op: u16) u4 {
    return @intCast((op & 0x0F00) >> 8);
}

pub fn opY(op: u16) u4 {
    return @intCast((op & 0x00F0) >> 4);
}

pub fn opN(op: u16) u4 {
    return @intCast(op & 0x000F);
}

pub fn opNN(op: u16) u8 {
    return @truncate(op & 0x00FF);
}

pub fn opNNN(op: u16) u12 {
    return @intCast(op & 0x0FFF);
}

test "opX extracts bits 11..8" {
    try std.testing.expectEqual(@as(u4, 0x0), opX(0x0000));
    try std.testing.expectEqual(@as(u4, 0xF), opX(0xFFFF));
    try std.testing.expectEqual(@as(u4, 0x3), opX(0x83A5));
}

test "opY extracts bits 7..4" {
    try std.testing.expectEqual(@as(u4, 0x0), opY(0x0000));
    try std.testing.expectEqual(@as(u4, 0xF), opY(0xFFFF));
    try std.testing.expectEqual(@as(u4, 0xA), opY(0x83A5));
}

test "opN extracts bits 3..0" {
    try std.testing.expectEqual(@as(u4, 0x0), opN(0x0000));
    try std.testing.expectEqual(@as(u4, 0xF), opN(0xFFFF));
    try std.testing.expectEqual(@as(u4, 0x5), opN(0x83A5));
}

test "opNN extracts bits 7..0" {
    try std.testing.expectEqual(@as(u8, 0x00), opNN(0x0000));
    try std.testing.expectEqual(@as(u8, 0xFF), opNN(0xFFFF));
    try std.testing.expectEqual(@as(u8, 0xA5), opNN(0x83A5));
}

test "opNNN extracts bits 11..0" {
    try std.testing.expectEqual(@as(u12, 0x000), opNNN(0x0000));
    try std.testing.expectEqual(@as(u12, 0xFFF), opNNN(0xFFFF));
    try std.testing.expectEqual(@as(u12, 0x3A5), opNNN(0x83A5));
}
