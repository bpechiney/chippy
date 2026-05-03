# Vendored test ROMs

These ROMs are committed verbatim so the verification spine (ADR 0004) is
self-contained: tests load them at runtime (see the file-level doc in
`src/core/golden_harness.zig` for the `@embedFile` package-path constraint
that motivates this), and CI re-runs the exact bytes any contributor sees
locally.

## `ibm_logo.ch8`

- **Source:** `bin/2-ibm-logo.ch8` from
  [Timendus/chip8-test-suite](https://github.com/Timendus/chip8-test-suite),
  retrieved 2026-05-03.
- **License:** GPL-3.0, matching this repo's own license.
- **Underlying authorship:** the IBM logo ROM is the well-known public-domain
  ROM by Joseph Weisbecker, distributed widely since ~1977 and bundled by
  the Timendus suite as its first sanity-check ROM.
- **SHA-256:** `00072a250d2f7ccaa3ecc0182bac73e63c168abab96d7ea2df5eba6a4da49067`
- **Size:** 132 bytes.
- **Behavior:** clears the screen, draws the letters "IBM" via six DXYN
  sprites, then `JP`s to itself in a terminal infinite loop. Cycle count
  bumped from 30 to 100 in M3.3 to give the vBlank-wait stall path enough
  budget; see ADR 0012. Captured bytes unchanged
  (`tests/test_goldens/ibm_logo_after_100_cycles.bin`).

## `corax_plus.ch8`

- **Source:** `bin/3-corax+.ch8` from
  [Timendus/chip8-test-suite](https://github.com/Timendus/chip8-test-suite),
  retrieved 2026-05-03.
- **License:** GPL-3.0, matching this repo's own license.
- **Underlying authorship:** corax89's CHIP-8 opcode self-test
  (`corax89/chip8-test-rom`), adopted into Timendus's suite as the third
  bundled ROM. Verifies CHIP-8 opcode behavior cell-by-cell on a 4×6
  grid: 1NNN, 2NNN, 00EE, 3XNN, 4XNN, 5XY0, 7XNN, 9XY0, 8XY0–8XY7,
  8XYE, FX55, FX65, FX33, FX1E, plus a register-overflow test. Each
  cell shows the opcode mnemonic followed by a tiny checkmark on pass
  or a cross on fail; the bottom-right cell renders a `v4.2` version
  label.
- **SHA-256:** `1c7e14eae14d6d5e1e47693804110354cbc4081defe4e6e5d9167c25ffc7b4b0`
- **Size:** 761 bytes.
- **Behavior:** runs each opcode test in sequence, draws the result
  cell, then `JP`s to itself once the grid is fully drawn. The
  framebuffer stabilizes by cycle ~350; the golden snapshot is taken at
  cycle 1000 (`tests/test_goldens/corax_plus_after_1000_cycles.bin`)
  for a comfortable safety margin while keeping the test sub-millisecond.
  The committed golden bytes match Timendus's published reference
  screenshot pixel-for-pixel.

## `keypad.ch8`

- **Source:** `bin/6-keypad.ch8` from
  [Timendus/chip8-test-suite](https://github.com/Timendus/chip8-test-suite),
  retrieved 2026-05-03. Upstream git-blob
  `4d1ecdccdf6968522529fff4a18492cd31032600`.
- **License:** GPL-3.0, matching this repo's own license.
- **Underlying authorship:** Timendus's keypad-test ROM (sixth bundled
  test). Verifies all three CHIP-8 keypad opcodes against scripted
  input: EX9E (skip-if-key-down), EXA1 (skip-if-key-up), and FX0A
  (GETKEY blocking with two-phase claim/release per ADR 0013).
- **SHA-256:** `558902b0e406bb97dc808c16d55abf493706598246e3c77aea9d9401063169c9`
- **Size:** 913 bytes.
- **Behavior:** at boot, reads `RAM[0x1FF]` and dispatches directly to
  one of three subtests if the byte is 1, 2, or 3 (1 = `keypad-down`
  EX9E, 2 = `keypad-up` EXA1, 3 = `keypad-getkey` FX0A); otherwise
  draws an interactive menu with a blinking cursor and keypad-driven
  navigation. The EX9E and EXA1 subtests render a 4×4 keypad layout
  and XOR a cursor sprite into each key's cell whose skip condition
  fires on the current keypad state; both subtests are infinite loops
  with no menu return path. The FX0A subtest sets the delay timer to
  3, blocks on `v0 := key`, then verifies on consume that the timer
  reached 0 (NOT-HALTING gate) and that the claimed key is up
  (NOT-RELEASED gate) before drawing "ALL GOOD" + a checkmark and
  blocking on a second FX0A. The M4.4 golden harness drives all four
  checkpoints (menu, EX9E with keys 1+6, EXA1 with keys 1+6, FX0A
  ALL-GOOD after press@cycle 350 / release@cycle 400) via the shared
  scripted-input helper at `src/core/scripted_input.zig`. Each subtest
  runs in its own `Machine` instance because the EX9E/EXA1 subtests
  are dead-end loops with no menu return path. Empirical cycle counts:
  menu @2000 (cursor-visible blink-phase plateau), down @2000, up
  @5000, getkey @5000 — see PR description for the full M2.11-style
  stability sweep.

## `quirks.ch8`

- **Source:** `bin/5-quirks.ch8` from
  [Timendus/chip8-test-suite](https://github.com/Timendus/chip8-test-suite),
  retrieved 2026-05-03.
- **License:** GPL-3.0, matching this repo's own license.
- **Underlying authorship:** Timendus's quirks-test ROM (fifth bundled
  test). Verifies all six CHIP-8 quirk gates against a per-platform
  preset: VF reset on logical, FX55/FX65 I increment, vBlank wait on
  draw, display clipping, shift source, and BNNN jump base. Renders a
  pass/fail indicator per quirk on a results grid.
- **SHA-256:** `d839350268a3e73c7a16562b3d23c85aa1b92a567f5f61bd6727b1ea44635679`
- **Size:** 3232 bytes.
- **Behavior:** at boot, reads `RAM[0x1FF]` to choose the platform
  preset (1 = CHIP-8/COSMAC VIP, 2 = SUPER-CHIP modern, 3 = SUPER-CHIP
  legacy, 4 = XO-CHIP); displays a menu if the byte is zero. Tests then
  enter a `SKNP V0` / `JP self` wait loop at `$204` until key 0 is not
  pressed (default keypad state, requires `EXA1` to be implemented).
  This dependency on `EXA1` is why the keystone gate (`5-quirks.ch8`
  golden) was deferred from M3.4 to M4 — see issue #71 and the
  `71-quirks-rom-golden` branch where the ROM + reference screenshot
  + grilling notes were vendored in advance.
