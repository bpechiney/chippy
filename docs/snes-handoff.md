# SNES Handoff

Forward-looking brief for the eventual SNES emulator project. This file is **living** — bullets get added the moment a chippy lesson crystallizes, not deferred to retro time. At SNES kickoff, this is the literal first read.

Each bullet should link back to the chippy retro that motivated it (e.g., "see `docs/retros/M3.md`").

## Do

- **Two-artifact split (core module + thin exe) from day one.** Pays off immediately: CI matrix never resolves a graphics dep, headless determinism is enforceable by construction, SNES test ROMs run on the test runner. (See `docs/retros/M0.md`.)
- **Field-by-field `serialize`/`deserialize` from the first commit, never `std.mem.asBytes` on a struct.** Padding bytes inside structs are ABI- and compiler-version-dependent; raw struct serialization breaks save-state files when fields move. Same shape SNES will need across cartridge / region / mapper variants. (See `docs/retros/M0.md`, reviewer finding on PR #4.)
- **Brief out-of-line comments on "wraps quietly" semantics in core paths that handle ROM-derived addresses.** When chippy's `Bus.read16` masks at 12 bits, the wrap-around on the second byte fetch is non-obvious; SNES address spaces are larger and have more legitimate boundary conditions, so the same documentation discipline matters more there. (See `docs/retros/M0.md`, reviewer finding on PR #4.)

## Avoid

- **`cachix/install-nix-action` on macOS runners.** Pre-provisioned `_nixbld1` collides with `eDSRecordAlreadyExists`. Use `DeterminateSystems/nix-installer-action@v17` + `magic-nix-cache-action@v9` instead. (See `docs/retros/M0.md`.)
- **Cold-read reviewer agents without the linked issue body.** The `feature-dev:code-reviewer` agent run on PR #4 read `CLAUDE.md`, `CONTEXT.md`, the ADRs, and the diff — but did **not** fetch the GitHub issue listing the acceptance criteria, and so flagged in-spec methods (`runUntil`, `deinit`) for removal. **For SNES, every reviewer-agent prompt must include either the issue body inline or an explicit `gh issue view` instruction.** (See `docs/retros/M0.md`.)
- **GitHub task-list checkboxes with descriptive prefixes.** `- [ ] **M0 — ...** → #1` does not auto-tick when #1 closes; only the bare `- [ ] #1` form does. SNES roadmap should use the bare form, or accept manual ticks. (See `docs/retros/M0.md`.)

## Reconsider

- **Tier 2 CLI debug REPL was deferred to "on demand" for chippy.** SNES address space and per-frame instruction count are dramatically larger; revisit whether the REPL should land in the SNES walking skeleton rather than waiting for a forcing function.
- **The `serialize` save-state format is currently field-by-field with no version header.** Fine for chippy (one schema version, lifetime measured in months). For SNES — long-lived saves, multiple cartridge mappers, eventual save-state forwards-compat — add a 4-byte magic + 2-byte version at the front from the first SNES commit.
- **CI runs `nix develop -c zig fmt --check`. The `fmt` step is currently after build and tests** — fast-failing is generally better. Reorder for SNES so a formatting violation is the first red.
