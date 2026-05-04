//! Golden-snapshot harness for Timendus's 7-beep.ch8 (ADR 0004 + ADR 0015).
//!
//! Third M5 keystone gate: 7-beep.ch8 emits SOS in morse code via FX18
//! sound-timer writes paired with a speaker sprite drawn at (28, 12).
//! Asserts byte-equality on TWO goldens at the same plateau-pinned frame
//! N=268: the framebuffer (post-SOS speaker-erased state) and the audio
//! bool stream (0x00 / 0x01 per frame, encoding the morse pattern).
//!
//! Why `runFrame` (not `runCycles`): this ROM is timer-driven by design.
//! Each pattern iteration writes ST and DT (FX18 + FX15) to the same
//! beep-length value, then enters a software wait loop reading FX07
//! until DT reaches 0. `runCycles` advances the CPU but does NOT call
//! `timing.tick()` — without ticks DT never decrements, the wait loop
//! never exits, and the audio sink (which fires post-tick from
//! `runFrame`'s tail per ADR 0015) never samples. Only `runFrame`
//! produces the frame-aligned audio bool stream this golden asserts on.
//! Same loop-primitive lesson the M4.2 5-quirks golden codified —
//! pick `runFrame` whenever the ROM relies on timer-driven behaviour.
//!
//! N=268 chosen empirically per `verify/verify_beep.zig`'s plateau search:
//! - Across a 600-frame run, the audio bool stream produces 38 plateau
//!   segments; the longest silent plateau spans frames 236–299 (64
//!   frames wide), centred at 268.
//! - At frame 268 the framebuffer is the post-SOS speaker-erased state
//!   (all-zero); audio[0..268] encodes the full SOS — 3 dots, 3 dashes,
//!   3 dots — with the timed silent gaps, plus 33 frames of post-pattern
//!   silence at the tail.
//! - Per the M4.4 oscillating-framebuffer plateau-pinning lesson, the
//!   plateau centre is the most robust pin point: ±32 frames of cycle-
//!   count drift would still land inside the plateau.

const chippy = @import("chippy_core");
const harness = @import("golden_harness.zig");

const ROM_PATH = "tests/test_roms/beep.ch8";
const FRAMEBUFFER_GOLDEN = "tests/test_goldens/beep_after_268_frames.bin";
const AUDIO_GOLDEN = "tests/test_goldens/beep_audio_after_268_frames.bin";
const KEYSTONE_FRAMES: u32 = 268;

test "7-beep: framebuffer + audio bool stream after 268 frames matches goldens (full SOS + post-pattern silence)" {
    var audio_buf: [KEYSTONE_FRAMES]bool = undefined;
    var rec: harness.AudioRecording = .{ .buf = &audio_buf };
    try harness.runAndCompare(.{
        .rom_path = ROM_PATH,
        .golden_path = FRAMEBUFFER_GOLDEN,
        .run = .{ .frames = KEYSTONE_FRAMES },
        .audio_recording = &rec,
        .audio_golden_path = AUDIO_GOLDEN,
    });
}
