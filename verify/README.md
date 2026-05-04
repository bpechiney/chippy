# `verify/` — empirical pre-flight scratch programs

These are non-shipping scratch utilities used during PRD-validation and
acceptance-gate work to produce trace evidence that PRDs and issue bodies
must cite. They live here (not in `tests/`) because they are diagnostic
tools, not regression contracts: the integration tests in `tests/integration/`
carry the cross-runner-determinism gate, the verify programs surface the
empirical findings that anchor each test's choice of cycle / frame N,
opcode coverage, and blocking-opcode set.

## Build invocation

Each verify program is a standalone Zig file that imports `chippy_core` and
runs from the repo root. Locked invocation:

```sh
nix develop -c zig run --dep chippy_core \
  -Mroot=verify/<name>.zig \
  -Mchippy_core=src/core/root.zig
```

The two `-M…` flags name the entry-point module and its dependency by path —
this is the same shape `build.zig` uses for the integration-test module
(ADR 0014). The verify program does **not** route through `zig build` because
each scratch utility is independent and adding build steps for non-shipping
diagnostics is rule-10 / rule-7 friction. The invocation runs from the repo
root (CWD = repo root) because verify programs use runtime relative paths
(`tests/test_roms/<rom>.ch8`) — same constraint that `tests/integration/`
inherits.

## Available programs

- `verify_beep.zig` — multi-window pre-flight trace for `tests/test_roms/beep.ch8`
  (M5.3, issue #103). Encodes the M3 retro `verify/`-pattern bullet and
  the M4.2 multi-window refinement: boot / mid-test / post-test / idle
  windows, with per-window opcode counts, FX18 calls + V[X] values,
  blocking-stall counts, and audio bool-stream plateau lengths. Plateau
  search across the full stream identifies the keystone N for the M5.3
  goldens (`beep_after_<N>_frames.bin`, `beep_audio_after_<N>_frames.bin`).
