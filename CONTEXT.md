# Chippy

A vanilla COSMAC VIP CHIP-8 emulator in Zig. The codebase is structured as a deliberate stepping-stone toward a future SNES emulator — module boundaries, state-serialization shape, and the verification harness are intended to carry forward.

## Language

**Opcode**:
A 16-bit instruction word, fetched from RAM as two bytes (big-endian). The CHIP-8 instruction set has 35 opcodes.
_Avoid_: instruction (when meaning the binary form), op, command

**Instruction**:
A single decoded operation that the CPU executes. One instruction per opcode.
_Avoid_: command

**Cycle**:
The unit of CPU advancement. For CHIP-8, one cycle equals one instruction. Reserved for sub-instruction granularity in future projects (e.g., Game Boy M-cycles / T-cycles, NES PPU dot timing, SNES sub-instruction cycles).
_Avoid_: tick, step (when meaning a unit of progress)

**Frame**:
One 60 Hz update window. Defined as `cycles_per_second / 60` cycles followed by exactly one delay-and-sound timer tick.
_Avoid_: refresh, tick

**Sprite**:
A 1-bit bitmap drawn by the `DXYN` opcode. Width is fixed at 8 pixels; height is the `N` nibble (1–15 rows). Drawn via XOR with collision detection into `vF`.

**Framebuffer**:
The 64×32 1-bit display memory. The CPU XORs sprites into it; the renderer (TUI from M1, raylib from M6) reads it for display.
_Avoid_: screen, display memory, vram

**Delay timer**:
An 8-bit register that decrements at 60 Hz down to zero. Read via `FX07`, set via `FX15`. Used by ROMs to time gameplay events.

**Sound timer**:
An 8-bit register that decrements at 60 Hz down to zero. Set via `FX18`. While non-zero, the beeper is on.

**Keypad**:
The 16-key hex input device. Keys are addressed `0x0`–`0xF`. ROMs poll via `EX9E` / `EXA1` and block-read via `FX0A`.
_Avoid_: keyboard (which is the host input device translated by the frontend)

**Awaited key**:
The single-key claim slot `FX0A` uses to track its two-phase wait. Phase 1 (no claim): scan held **Keypad** keys, claim the lowest. Phase 2 (claim active): wait for that key's release. Pre-FX0A noise is discarded. Null between FX0A invocations. See ADR 0013.
_Avoid_: latch, last-released, key buffer

**Quirk**:
A behavioral ambiguity in the original CHIP-8 spec where reference platforms or interpreters disagreed. Examples: which register sources the shift in `8XY6` / `8XYE`; whether `FX55` / `FX65` increments `I`; whether `BNNN` adds `V0` or `VX`. Captured per-instance in the `Quirks` config struct.

**V registers**:
The 16 8-bit general-purpose registers `V0`–`VF`. `VF` doubles as a flag register (carry, borrow, collision).
_Avoid_: variables, V

**I register**:
The 16-bit address register, used as the source/target for memory and sprite-draw operations.
_Avoid_: index register

**Stack**:
A 16-entry stack of 16-bit return addresses, pushed by `2NNN` (call) and popped by `00EE` (return). Overflow is undefined in the original spec; we treat it as an internal logic error.

**vBlank**:
The end of a 60 Hz display frame. In vanilla CHIP-8 the `DXYN` opcode stalls the CPU until the next vBlank before drawing — a quirk that some games depend on for timing.
_Avoid_: blank, vsync

## Relationships

- A **Frame** consists of N **Cycles** plus one tick of the **Delay timer** and **Sound timer**.
- A **Cycle** executes exactly one **Instruction**, decoded from one **Opcode**.
- An **Instruction** may read or write any of the **V registers**, the **I register**, the **Stack**, the **Framebuffer**, the **Keypad**, or RAM.
- A **Quirk** modifies the semantics of a specific **Opcode** or family.
- The `DXYN` **Instruction** writes a **Sprite** into the **Framebuffer** by XOR; the original spec stalls until **vBlank** before doing so.

## Example dialogue

> **Dev:** "When I run the IBM logo ROM, it draws once and then stops doing anything. Is that wrong?"
> **Domain expert:** "No. The IBM logo program is a sequence of seven **Instructions** that clear the **Framebuffer**, set the **I register** to a sprite address, draw a **Sprite** with `DXYN`, and finish in a tight infinite loop. There's no animation in this ROM — its **Cycles** continue executing the loop opcode forever, but the **Framebuffer** doesn't change after the initial draw. That's correct behavior."

## Flagged ambiguities

- "instruction" was being used to mean both the binary opcode and the executed operation — resolved: **Opcode** is the binary form, **Instruction** is the executed operation.
- "tick" was being used for both **Cycle** advancement and 60 Hz timer decrement — resolved: tick is reserved for the 60 Hz timer event; **Cycle** is the CPU-advancement unit.
