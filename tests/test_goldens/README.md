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
