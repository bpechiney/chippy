//! ROM byte-slice validation. File reading is the frontend's job; this
//! module is pure data validation so it stays in `chippy_core` without
//! pulling in `std.fs`.

const bus = @import("bus.zig");

pub const RomError = error{RomTooLarge};

pub fn validate(bytes: []const u8) RomError!void {
    if (bytes.len > bus.ROM_MAX_BYTES) return error.RomTooLarge;
}
