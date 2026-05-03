//! 16-key hex keypad. `state` is a bitmask (bit N set = key N down).
//! `awaiting_release` is the per-FX0A claim slot: null between FX0A
//! invocations, so pre-FX0A keypad noise can't satisfy the next FX0A.
//! See ADR 0013.

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
};
