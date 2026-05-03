//! Test runner root for `tests/integration/`. This module imports
//! `chippy_core` only via its public API — no sibling reaches into
//! `src/core/` internals — so the public surface is the literal
//! integration-test surface (ADR 0014). Unit tests stay inline in
//! `src/core/*.zig` where they need internal field access.

test {
    _ = @import("golden_ibm_logo.zig");
    _ = @import("golden_corax_plus.zig");
    _ = @import("golden_quirks.zig");
    _ = @import("golden_keypad.zig");
    _ = @import("scripted_input.zig");
    _ = @import("golden_harness.zig");
}
