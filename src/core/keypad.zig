//! 16-key hex keypad. `state` is a bitmask (bit N set = key N down).
//! `last_released` retains the most recently released key so `FX0A` (which
//! blocks until a key is *released*, not pressed) has something to read.

pub const Keypad = struct {
    state: u16 = 0,
    last_released: ?u4 = null,

    pub fn setKey(self: *Keypad, key: u4, down: bool) void {
        const bit = @as(u16, 1) << key;
        if (down) {
            self.state |= bit;
        } else {
            if (self.state & bit != 0) self.last_released = key;
            self.state &= ~bit;
        }
    }

    pub fn isDown(self: *const Keypad, key: u4) bool {
        return (self.state & (@as(u16, 1) << key)) != 0;
    }
};
