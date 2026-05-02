//! Tier 1 debug affordance: opcode disassembly. Pure function so it's safe
//! to call from any context (trace formatting, debugger UI, test failure
//! messages). M0 returns `.unknown` for everything; cases get filled in as
//! opcodes ship.

pub const DisasmEntry = struct {
    mnemonic: []const u8,

    pub const unknown = DisasmEntry{ .mnemonic = "???" };
};

pub fn disasm(opcode: u16) DisasmEntry {
    _ = opcode;
    return DisasmEntry.unknown;
}
