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
  sprites, then `JP`s to itself in a terminal infinite loop. All draws
  finish well before cycle 30, which is the cycle count the golden
  snapshot is taken at (`tests/test_goldens/ibm_logo_after_30_cycles.bin`).
