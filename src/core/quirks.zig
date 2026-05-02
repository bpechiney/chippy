//! Behavioral toggles for ambiguous CHIP-8 instructions. Defaults are vanilla
//! COSMAC VIP. M3 wires each flag into its opcode body; M0 just declares the
//! struct so callers and Options can reference it.

pub const Quirks = struct {
    /// `8XY6`/`8XYE`: shift VX in place (true) instead of shifting VY into VX
    /// (false, vanilla).
    shift_in_place: bool = false,
    /// `FX55`/`FX65`: leave I unchanged (true) instead of incrementing I after
    /// each byte (false, vanilla).
    no_index_increment: bool = false,
    /// `BNNN`: jump to NNN+VX (true) instead of NNN+V0 (false, vanilla).
    jump_uses_vx: bool = false,
    /// `8XY1`/`8XY2`/`8XY3`: clear VF after the operation (true, vanilla).
    vf_reset_on_logical: bool = true,
    /// `DXYN`: clip sprites at the screen edges (true, vanilla) instead of
    /// wrapping.
    display_clipping: bool = true,
    /// `DXYN`: stall the CPU until the next 60 Hz tick (true, vanilla).
    vblank_wait_on_draw: bool = true,

    pub const vanilla: Quirks = .{};
};
