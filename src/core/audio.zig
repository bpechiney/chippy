//! Beeper predicate. CHIP-8 has a single tone that's on whenever the sound
//! timer is non-zero — there is no audio state inside the core today. M5
//! grows a sample-stream contract here when the SNES-shaped audio path
//! needs rehearsing.

pub fn isBeeping(sound_timer: u8) bool {
    return sound_timer > 0;
}
