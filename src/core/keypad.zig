//! 16-key hex keypad. `state` is a bitmask (bit N set = key N down).
//! `awaiting_release` is the per-FX0A claim slot: null between FX0A
//! invocations. Mutated only by Keypad methods (CI grep enforced) so
//! the ADR 0013 invariant lives in the type, not in convention.

const std = @import("std");

pub const Keypad = struct {
    state: u16 = 0,
    awaiting_release: ?u4 = null,

    pub fn setKey(self: *Keypad, key: u4, down: bool) void {
        const bit = @as(u16, 1) << key;
        if (down) {
            self.state |= bit;
        } else {
            self.state &= ~bit;
        }
    }

    pub fn isDown(self: *const Keypad, key: u4) bool {
        return (self.state & (@as(u16, 1) << key)) != 0;
    }

    /// True iff an FX0A claim is active (phase 2). See ADR 0013.
    pub fn isAwaiting(self: *const Keypad) bool {
        return self.awaiting_release != null;
    }

    /// One cycle of FX0A's two-phase wait. Pre-claim release events are
    /// discarded (VIP-faithful). See ADR 0013.
    pub fn pollAwaitedKey(self: *Keypad) ?u4 {
        if (self.awaiting_release) |claimed| {
            if (self.isDown(claimed)) return null;
            self.awaiting_release = null;
            return claimed;
        }
        for (0..16) |i| {
            const key: u4 = @intCast(i);
            if (self.isDown(key)) {
                self.awaiting_release = key;
                break;
            }
        }
        return null;
    }

    /// Save-state codec: u16 state (big-endian) + u8 slot (0xFF = null).
    /// Bytes match the format `Machine.serialize` previously inlined for
    /// keypad fields, so existing save-state files round-trip unchanged.
    pub fn serialize(self: *const Keypad, writer: anytype) !void {
        try writer.writeInt(u16, self.state, .big);
        try writer.writeInt(u8, self.awaiting_release orelse 0xFF, .big);
    }

    pub fn deserialize(reader: anytype) !Keypad {
        const state = try reader.takeInt(u16, .big);
        const slot = try reader.takeByte();
        return .{
            .state = state,
            .awaiting_release = if (slot == 0xFF) null else @intCast(slot),
        };
    }
};

test "pollAwaitedKey: phase 1 with no key held returns null and stays unclaimed" {
    var k: Keypad = .{};

    try std.testing.expectEqual(@as(?u4, null), k.pollAwaitedKey());
    try std.testing.expect(!k.isAwaiting());
}

test "pollAwaitedKey: phase 1 claims lowest-indexed held key (proven via consume)" {
    var k: Keypad = .{};
    k.setKey(0xA, true);
    k.setKey(0x3, true);
    k.setKey(0xC, true);

    try std.testing.expectEqual(@as(?u4, null), k.pollAwaitedKey());
    try std.testing.expect(k.isAwaiting());

    // Releasing 0x3 must satisfy the next poll — proves 0x3 was claimed,
    // not 0xA or 0xC.
    k.setKey(0x3, false);
    try std.testing.expectEqual(@as(?u4, 0x3), k.pollAwaitedKey());
}

test "pollAwaitedKey: phase 2 returns null while claimed key still held" {
    var k: Keypad = .{};
    k.setKey(0x7, true);
    _ = k.pollAwaitedKey();

    try std.testing.expectEqual(@as(?u4, null), k.pollAwaitedKey());
    try std.testing.expect(k.isAwaiting());
}

test "pollAwaitedKey: phase 2 consume — claimed key released yields Some(K), clears slot" {
    var k: Keypad = .{};
    k.setKey(0x7, true);
    _ = k.pollAwaitedKey();
    k.setKey(0x7, false);

    try std.testing.expectEqual(@as(?u4, 0x7), k.pollAwaitedKey());
    try std.testing.expect(!k.isAwaiting());
}

test "pollAwaitedKey: pre-claim release events do not satisfy a later poll (VIP-faithful)" {
    var k: Keypad = .{};
    k.setKey(0x1, true);
    k.setKey(0x1, false);
    k.setKey(0xB, true);
    k.setKey(0xB, false);

    try std.testing.expectEqual(@as(?u4, null), k.pollAwaitedKey());
    try std.testing.expect(!k.isAwaiting());
}

test "Keypad codec: round-trip preserves state bitmask with null awaiting_release" {
    var src: Keypad = .{};
    src.setKey(0x3, true);
    src.setKey(0xA, true);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.serialize(&aw.writer);

    var reader = std.Io.Reader.fixed(aw.written());
    const dst = try Keypad.deserialize(&reader);

    try std.testing.expectEqual(src.state, dst.state);
    try std.testing.expectEqual(@as(?u4, null), dst.awaiting_release);
}

test "Keypad codec: round-trip preserves Some(K) awaiting_release" {
    var src: Keypad = .{};
    src.setKey(0x9, true);
    _ = src.pollAwaitedKey();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.serialize(&aw.writer);

    var reader = std.Io.Reader.fixed(aw.written());
    const dst = try Keypad.deserialize(&reader);

    try std.testing.expectEqual(src.state, dst.state);
    try std.testing.expectEqual(@as(?u4, 0x9), dst.awaiting_release);
}
