//! Cycle counter and 60 Hz delay/sound timer state. `Cycles` is `u64` so
//! long-running tests don't wrap (u32 wraps in roughly 70 minutes at 1 MHz,
//! enough for CHIP-8 but not for SNES).

pub const Cycles = u64;

pub const Timing = struct {
    cycles: Cycles = 0,
    delay_timer: u8 = 0,
    sound_timer: u8 = 0,

    pub fn tick(self: *Timing) void {
        if (self.delay_timer > 0) self.delay_timer -= 1;
        if (self.sound_timer > 0) self.sound_timer -= 1;
    }
};
