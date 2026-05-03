# Vendored test ROMs

These ROMs are committed verbatim so the verification spine (ADR 0004) is
self-contained: tests load them at runtime (see the file-level doc in
`src/core/golden_ibm_logo.zig` for the `@embedFile` package-path constraint
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
