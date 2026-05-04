# Vendored test goldens

These goldens are committed verbatim alongside the test ROMs they
verify. Two kinds live here:

- **Captured framebuffer snapshots** (`*_after_N_<unit>.bin`): packed
  64×32 1-bit framebuffer (256 bytes, row-major, MSB = leftmost pixel)
  produced by running the corresponding ROM for `N` cycles or frames
  under vanilla COSMAC VIP defaults. These are the cross-runner
  determinism gate (ADR 0004) — CI re-runs each ROM and asserts the
  bytes match. Re-baseline via `UPDATE_GOLDENS=1`. **Any re-baseline
  must be re-anchored against the corresponding reference screenshot
  below at PR review time** — the captured `.bin` is the regression
  contract going forward, but its initial correctness is anchored
  externally.
- **Reference screenshots** (`*.png`): published images from the
  upstream test suite, kept here as the reviewer's eyeball-gate
  reference at PR review time. The runtime PNG decode + pixel-equality
  test originally specified in M2.11 was de-scoped for chippy in M4.2
  (issue #79) — the cost (~150 LOC of test-only PNG decoder, non-carry
  -forward to Game Boy) was asymmetric to a one-time correctness anchor
  the reviewer can verify by rendering the captured `.bin` and
  comparing cell-by-cell against the PNG in seconds. Cross-runner
  determinism via the captured `.bin` carries the regression load
  forward; provenance + SHA-256 below preserve the audit chain.

## `keypad-menu.png`, `keypad-down.png`, `keypad-up.png`, `keypad-getkey.png`

- **Source:** `pictures/keypad-menu.png`, `pictures/keypad-down.png`,
  `pictures/keypad-up.png`, `pictures/keypad-getkey.png` from
  [Timendus/chip8-test-suite](https://github.com/Timendus/chip8-test-suite),
  retrieved 2026-05-03.
- **License:** GPL-3.0, matching this repo's own license.
- **Sizes (file / image):**
  - `keypad-menu.png` 10 096 bytes; 768 × 384 RGBA (clean 12× upscale of the 64 × 32 framebuffer).
  - `keypad-down.png` 8 734 bytes; 768 × 384 RGBA.
  - `keypad-up.png` 9 487 bytes; 768 × 384 RGBA.
  - `keypad-getkey.png` 7 583 bytes; 768 × 384 RGBA.
- **SHA-256:**
  - `keypad-menu.png`: `41d4dacccd9b0a9269293a48690d8a1e69b816288ea5098f346129e739f27824`
  - `keypad-down.png`: `90174c687395e23e2a396b5ebbde6d5beabec7f4726cd9da3a53ca84ee0924bb`
  - `keypad-up.png`: `688bd7d38fec56cabed3149791d2fbd8808b3f098e0544330b92eb5cda4b7a14`
  - `keypad-getkey.png`: `9dac01edb017a1c383a0eb67a35fbc2f2654525ee91b9b2ce45cd059fc5dbc41`
- **Represents — which checkpoint of the scripted timeline:**
  - `keypad-menu.png` — the boot menu after `pokeRam(0x1FF, 0)`, with
    the blinking cursor visible next to "1 EX9E DOWN" (the
    `MENU_CYCLES = 2000` checkpoint pins the cursor-visible blink
    phase). Anchors `keypad_menu_after_2000_cycles.bin`.
  - `keypad-down.png` — the EX9E (`keypad-down`) subtest after
    `pokeRam(0x1FF, 1)` with keys 1 and 6 held — cursor sprites
    appear over key cells 1 and 6 (the only cells where SKP fires
    with the current keypad state). Anchors
    `keypad_down_after_2000_cycles.bin`.
  - `keypad-up.png` — the EXA1 (`keypad-up`) subtest after
    `pokeRam(0x1FF, 2)` with keys 1 and 6 held — cursor sprites
    appear over every key cell *except* 1 and 6 (SKNP fires for
    every cell whose key is up). Anchors
    `keypad_up_after_5000_cycles.bin`.
  - `keypad-getkey.png` — the FX0A (`keypad-getkey`) subtest after
    `pokeRam(0x1FF, 3)` and a scripted press@cycle 350 / release@cycle 400
    sequence; the screen shows "ALL GOOD" + checkmark while the ROM
    blocks on its second FX0A. Anchors
    `keypad_getkey_after_5000_cycles.bin`.
- **Reviewer eyeball-gate:** each captured `.bin` was verified against
  its reference PNG at PR review time at 0/2048 px diff (sample-center
  downsampling at 12×). Cross-runner determinism via the captured
  `.bin` carries the regression load forward.

## `beep_after_268_frames.bin` and `beep_audio_after_268_frames.bin`

- **Source:** captured locally via `UPDATE_GOLDENS=1 zig build test` from
  `tests/test_roms/beep.ch8` (Timendus 7-beep) under vanilla COSMAC VIP
  `Options.quirks`, no scripted input.
- **Sizes:**
  - `beep_after_268_frames.bin` — 256 bytes (packed 64 × 32 framebuffer).
  - `beep_audio_after_268_frames.bin` — 268 bytes (one byte per frame,
    `0x00` = silent / `0x01` = beeping).
- **Frame count `N = 268`:** chosen via plateau search at
  `verify/verify_beep.zig` (M3-retro `verify/`-pattern + M4.2 multi-window
  refinement). Across a 600-frame run the audio bool stream produces
  38 plateau segments; the longest silent plateau spans frames 236–299
  (64 frames wide), centred at 268. Per the M4.4 oscillating-framebuffer
  plateau-pinning lesson the centre is the most robust pin point —
  ±32 frames of cycle-count drift would still land inside the plateau.
- **Framebuffer at `N = 268`:** the post-SOS speaker-erased state
  (all-zero, 256 bytes of `0x00`). The speaker sprite at (28, 12) was
  drawn during each beep and erased during each off-period via the
  same `DXYN`; at the centre of the post-pattern silent plateau the
  framebuffer has been all-zero for ~32 frames since iteration 9's
  erase. Any DXYN bug that left the speaker sprite rendered would
  fail the framebuffer assertion.
- **Audio bool-stream plateau structure for `audio[0..268]`:**
  - frame 0 (1 frame): silent (boot, before first FX18 fires)
  - frames 1–9 (9 frames): BEEP — dot 1 (S)
  - frames 10–17 (8 frames): silent
  - frames 18–26 (9 frames): BEEP — dot 2 (S)
  - frames 27–34 (8 frames): silent
  - frames 35–43 (9 frames): BEEP — dot 3 (S)
  - frames 44–66 (23 frames): silent (S → O inter-letter gap)
  - frames 67–95 (29 frames): BEEP — dash 1 (O)
  - frames 96–103 (8 frames): silent
  - frames 104–132 (29 frames): BEEP — dash 2 (O)
  - frames 133–140 (8 frames): silent
  - frames 141–169 (29 frames): BEEP — dash 3 (O)
  - frames 170–192 (23 frames): silent (O → S inter-letter gap)
  - frames 193–201 (9 frames): BEEP — dot 1 (S)
  - frames 202–209 (8 frames): silent
  - frames 210–218 (9 frames): BEEP — dot 2 (S)
  - frames 219–226 (8 frames): silent
  - frames 227–235 (9 frames): BEEP — dot 3 (S, end of pattern)
  - frames 236–267 (32 frames): silent (post-pattern; the 64-frame
    inter-cycle gap before `jump main` restarts the pattern at frame
    ~300)

  Beep durations (9-frame dots, 29-frame dashes) are one frame shorter
  than the FX18 V[0] values (10, 30) per the post-tick audio sampling
  contract documented in ADR 0015 — the final tick of each beep brings
  ST from 1 to 0, sampled as `0x00`.
- **Why `runFrame` (not `runCycles`):** see the docstring on
  `tests/integration/golden_beep.zig`. The ROM is timer-driven
  (FX15/FX18 + FX07-driven wait loops) and the audio sink fires
  post-tick from `runFrame`'s tail per ADR 0015 — `runCycles` produces
  no ticks and no audio samples.

## `quirks.png`

- **Source:** `pictures/quirks.png` from
  [Timendus/chip8-test-suite](https://github.com/Timendus/chip8-test-suite),
  retrieved 2026-05-03.
- **License:** GPL-3.0, matching this repo's own license.
- **SHA-256:** `6e2bd527e969f705d69ff8d4f26c6fdc07e07800f3040606cd0fe8cf90fe5731`
- **Size:** 11 326 bytes; 768 × 384 RGBA (clean 12× upscale of the
  64 × 32 CHIP-8 framebuffer, no decorative bezel).
- **Represents:** Timendus's published reference for `5-quirks.ch8`
  running with COSMAC VIP defaults — six rows showing each quirk's
  detected ON/OFF value plus a pass-marker checkmark. The
  `quirks_after_1000_frames.bin` snapshot is anchored against this
  image at PR review time and matches it cell-for-cell.
