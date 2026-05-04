//! Beeper predicate plus the M5.2 audio-recording seam. Vanilla CHIP-8 has
//! no audio state inside the core — `isBeeping(sound_timer)` is the entire
//! runtime payload (sampled at 60 Hz tick boundaries, on iff the sound timer
//! is non-zero). The opt-in `AudioSink` is a test-time recording shape
//! mirroring `TraceSink`: a bare struct with an opaque ctx pointer and a
//! `write` fn-pointer field that callers invoke directly. No allocation,
//! no state, no work when null. The seam (not the bool-per-frame payload)
//! is what carries forward to Game Boy's APU sink — see ADR 0015 and the
//! corresponding bullet in `docs/next-target-handoff.md`.

pub fn isBeeping(sound_timer: u8) bool {
    return sound_timer > 0;
}

pub const AudioSink = struct {
    write: *const fn (ctx: *anyopaque, beeping: bool) anyerror!void,
    ctx: *anyopaque,
};
