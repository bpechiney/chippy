# Vendored test goldens

These goldens are committed verbatim alongside the test ROMs they
verify. Two kinds live here:

- **Captured framebuffer snapshots** (`*_after_N_cycles.bin`): packed
  64×32 1-bit framebuffer (256 bytes, row-major, MSB = leftmost pixel)
  produced by running the corresponding ROM for `N` cycles under
  vanilla COSMAC VIP defaults. These are the cross-runner determinism
  gate (ADR 0004) — CI re-runs each ROM and asserts the bytes match.
  Re-baseline via `UPDATE_GOLDENS=1`.
- **Reference screenshots** (`*.png`): published images from the
  upstream test suite, kept here as the *reviewer's* eyeball-gate
  reference at PR review time. The runtime PNG decode + pixel-equality
  test originally specified in M2.11 was de-scoped for chippy in M4.2
  (issue #79) — the cost (~300 LOC of test-only PNG decoder, non-carry
  -forward to Game Boy) was asymmetric to a one-time correctness anchor
  the reviewer can verify by eye against the framed render in 5
  seconds. Cross-runner determinism via the captured `.bin` carries the
  regression load forward; provenance + SHA-256 below preserve the
  audit chain.

## `Cosmac-VIP-quirks.png`

- **Source:** `pictures/Cosmac-VIP-quirks.png` from
  [Timendus/chip8-test-suite](https://github.com/Timendus/chip8-test-suite),
  retrieved 2026-05-03.
- **License:** GPL-3.0, matching this repo's own license.
- **SHA-256:** `722d948179804b6eab469dbd25f1574dfb17ace655f4b18a9dcae7ae768b03cd`
- **Represents:** Timendus's published reference for `5-quirks.ch8`
  running with COSMAC VIP defaults — every quirk row shows a pass
  marker. Used by the reviewer at PR-review time as the eyeball-gate
  for the M4 `5-quirks.ch8` golden test (issue #79).
