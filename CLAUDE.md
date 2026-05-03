# CLAUDE.md

Operating manual for Claude sessions on chippy. Read once at session start.

## Project at a glance

Chippy is a vanilla COSMAC VIP CHIP-8 emulator in Zig 0.16. It is the first rung on a four-stage ladder — chippy → Game Boy → NES → SNES (see ADR 0010) — and a test-bed for AI-harness engineering. Decisions favor architectural patterns that carry forward (module boundaries, headless determinism, save-state shape) over CHIP-8-only minimalism. Game Boy is the immediate next target; "the next emulator" elsewhere in this document means GB unless otherwise noted.

## The non-negotiable rule

**No vibes, ever.** Every change is evidence-grounded — green tests, golden snapshots, trace diffs — never opinion. No "I'm pretty sure it works." No merging without verification. Slow is smooth, smooth is fast.

## Where to find things

- **Domain language:** `CONTEXT.md` (root). Update when introducing a new domain term.
- **Decisions:** `docs/adr/NNNN-*.md`. Append-only; supersede, don't edit.
- **Roadmap state:** Pinned GitHub roadmap meta-issue (`bpechiney/chippy#2`) with milestone checklist; sub-issues link from there. View with `gh issue view 2 --repo bpechiney/chippy`.
- **Lessons:** `docs/retros/MN.md` (frozen at write time) for what happened; `docs/next-target-handoff.md` (curated, living) for what the next emulator (Game Boy first) needs to do/avoid.
- **Skills registry:** `AGENTS.md`.
- **Plan-of-record:** `~/.claude/plans/we-need-to-nail-smooth-bird.md`.

## Build, test, run

All commands run inside the pinned dev shell:

- `nix develop -c zig build` — build core + frontend.
- `nix develop -c zig build test` — run all tests headlessly. **This is the merge gate.**
- `nix develop -c zig build run -- <rom>` — interactive run (TUI from M1, raylib from M6).
- `nix develop -c zig build run -- --print --cycles N <rom>` — one-shot framebuffer dump.
- `nix develop -c zig fmt src/ build.zig` — format. Run before commit.
- `just check` is shorthand for `nix develop -c zig build test`.

## Hard rules (enforced by reviewer agent and CI grep tests)

1. No code without tests in the same commit.
2. No features the issue didn't ask for.
3. No defensive validation for impossible cases. Validate only at real boundaries (user input, file IO).
4. No `unreachable` / `@panic` without a documented invariant comment naming what would have to be wrong.
5. No comments explaining WHAT — only WHY-non-obvious. Names should explain what.
6. No half-finished implementations marked done. No TODOs without a linked issue.
7. No commented-out code in commits.
8. Reuse before add — if a helper exists, use it.
9. Three similar lines beats a premature abstraction.
10. No backwards-compat shims. This is greenfield.
11. No mocks for things we own. Test the real `Bus`, `Cpu`, `Machine`.
12. **`chippy_core` invariants** (also CI-enforced via grep):
    - Never imports anything from `src/frontend/`.
    - Never calls `std.time.Timer` or any wall-clock function.
    - Never calls `std.crypto.random` or any OS-randomness function.
    - Never panics on input that came from a ROM. Internal logic errors only.

## Per-milestone loop

Wraps the per-PR loop. See ADR 0007.

1. **PRD first.** For M1 onward, run `/to-prd` (preceded by `/grill-with-docs` for heavyweight milestones — M3, M5, M6) to publish a structured milestone PRD as a `prd`-labeled, `needs-triage` GitHub issue. M0 is a degenerate case (its PRD is the plan + the M0 issue itself).
2. **Slice.** Triage the PRD into 1–N implementation sub-issues with acceptance criteria. Sub-issues link back to the PRD as parent.
3. **Triage to ready.** Move sub-issues from `needs-triage` to `ready-for-agent` (or `ready-for-human`).
4. **Implement.** Per sub-issue, run the per-PR loop below.
5. **Close.** After the last sub-issue merges: write `docs/retros/MN.md`, promote next-emulator-bound bullets to `docs/next-target-handoff.md`, close the PRD issue, tick the meta-issue checkbox.

## Per-PR loop

1. Pick `ready-for-agent` sub-issue. Branch `N-slug` from `master`.
2. Implement via `/tdd` — tracer-bullet red-green-refactor against the public surface declared in the agent brief. Tests and code land in the same commit. Test the real `Bus` / `Cpu` / `Machine` (rule 11). If the first failing test forces a contract decision the PRD did not make, stop and sharpen the PRD before continuing — that is the ambiguity signal, not a cue to keep coding. Enforced mechanically: a project-level PreToolUse hook (ADR 0009) blocks `Edit`/`Write`/`MultiEdit` on `src/**` while on an issue branch until `/tdd` is invoked in the current session.
3. `/simplify` on the diff.
4. `/commit`.
5. `/commit-push-pr`.
6. `/review` (or the `feature-dev:code-reviewer` agent) for cold-read review.
7. CI green on `ubuntu-latest` ∩ `macos-latest`.
8. Merge.

`/feature-dev:feature-dev` is no longer used (ADR 0008). Shape decisions belong in PRDs and ADRs; implementation always uses `/tdd`. Cross-module refactors that need shape exploration go through `/request-refactor-plan` and ship as their own PR.

## Other skills, when to use

- `/diagnose` — disciplined reproduce → minimize → root-cause loop. Whenever a test goes red unexpectedly. **Root cause, never symptom.** Flaky test = fix the determinism bug, never add retries.
- `/request-refactor-plan` — any cross-file refactor. Refactors are their own PR; never mixed with feature work.
- `/improve-codebase-architecture` — between milestones. **Mandatory before Game Boy kickoff** (and before each subsequent next-emulator handoff per ADR 0010).
- `/codex:rescue` — second-opinion / second-implementation pass when stuck.
- `/grill-with-docs` — non-trivial design, fuzzy terminology, decisions that probably need an ADR.
- `/revise-claude-md` — at session end, if invariants changed.

## Lessons capture

- Per-PR close: if a non-obvious lesson emerged, append a bullet to `docs/next-target-handoff.md` *now*. Don't defer.
- Per-milestone close: write `docs/retros/MN.md` (≤ 1 page). Promote next-emulator-bound bullets to handoff with back-reference.
- On architecture reversal: new ADR + retro/handoff update.
- `docs/retros/MN.md` is **frozen after write** — never edit; supersede if needed.

## What this project is *not*

- Not aiming for SUPER-CHIP or XO-CHIP compatibility (vanilla COSMAC VIP only). Stretch goal post-v1.
- Not building a graphical debugger UI (Tier 3 still deferred to SNES per ADR 0006; re-evaluate at Game Boy kickoff per ADR 0010 but no pre-commit).
- Not running on Windows in v1 (still deferred to SNES per ADR 0010; re-evaluate at Game Boy kickoff but no pre-commit).
- Not optimizing for performance (correctness and clarity first; CHIP-8 is trivially fast on any hardware).
