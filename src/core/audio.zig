//! Beeper predicate. CHIP-8 has a single tone that's on whenever the sound
//! timer is non-zero — there is no audio state inside the core today. M5
//! grows a sample-stream contract here as rehearsal for the next emulator's
//! audio path (Game Boy's 4-channel APU first).

pub fn isBeeping(sound_timer: u8) bool {
    return sound_timer > 0;
}
