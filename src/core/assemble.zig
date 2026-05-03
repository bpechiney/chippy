//! Comptime helper that turns CHIP-8 opcode literals into the big-endian
//! byte stream `Machine.loadRom` accepts. Lives in `chippy_core` so opcode
//! tests (here and elsewhere in the module) reach for it without crossing
//! the module boundary.

const std = @import("std");
const Machine = @import("machine.zig").Machine;

pub fn assemble(comptime opcodes: anytype) [opcodes.len * 2]u8 {
    var bytes: [opcodes.len * 2]u8 = undefined;
    inline for (opcodes, 0..) |op, i| {
        std.mem.writeInt(u16, bytes[i * 2 ..][0..2], op, .big);
    }
    return bytes;
}

test "assemble emits big-endian byte pairs that loadRom accepts" {
    const bytes = assemble(.{ 0x00E0, 0x1234 });
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xE0, 0x12, 0x34 }, &bytes);

    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&bytes);
    try std.testing.expectEqualSlices(u8, &bytes, m.bus.ram[0x200 .. 0x200 + bytes.len]);
}
