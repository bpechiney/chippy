//! Public surface of `chippy_core`. Frontend and tests `@import("chippy_core")`
//! and reach types via this re-export. Internal modules are not exposed.

const machine = @import("machine.zig");

pub const Machine = machine.Machine;
pub const StepResult = machine.StepResult;
pub const Options = @import("options.zig").Options;
pub const Quirks = @import("quirks.zig").Quirks;
pub const Framebuffer = @import("display.zig").Framebuffer;
pub const TraceSink = @import("trace.zig").TraceSink;
pub const disasm = @import("disasm.zig").disasm;
pub const DisasmEntry = @import("disasm.zig").DisasmEntry;
pub const RomError = @import("rom.zig").RomError;
pub const ROM_MAX_BYTES = @import("bus.zig").ROM_MAX_BYTES;
pub const assemble = @import("assemble.zig").assemble;
pub const opX = @import("decode.zig").opX;
pub const opY = @import("decode.zig").opY;
pub const opN = @import("decode.zig").opN;
pub const opNN = @import("decode.zig").opNN;
pub const opNNN = @import("decode.zig").opNNN;

test {
    _ = @import("machine.zig");
    _ = @import("bus.zig");
    _ = @import("cpu.zig");
    _ = @import("display.zig");
    _ = @import("keypad.zig");
    _ = @import("audio.zig");
    _ = @import("timing.zig");
    _ = @import("quirks.zig");
    _ = @import("rom.zig");
    _ = @import("disasm.zig");
    _ = @import("trace.zig");
    _ = @import("options.zig");
    _ = @import("assemble.zig");
    _ = @import("decode.zig");
    _ = @import("golden_ibm_logo.zig");
    _ = @import("golden_corax_plus.zig");
    _ = @import("golden_quirks.zig");
}
