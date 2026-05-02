const std = @import("std");

pub const ParsedArgs = struct {
    rom_path: ?[:0]const u8 = null,
    help: bool = false,
};

pub const Error = error{
    TooManyPositionalArgs,
};

pub fn parse(args: []const [:0]const u8) Error!ParsedArgs {
    var result: ParsedArgs = .{};
    if (args.len == 0) return result;

    var positional_count: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else {
            if (positional_count >= 1) return error.TooManyPositionalArgs;
            result.rom_path = arg;
            positional_count += 1;
        }
    }
    return result;
}

pub fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: chippy [options] <rom-path>
        \\
        \\Options:
        \\  --help, -h    Print this message
        \\
        \\More flags land in later milestones.
        \\
    );
}

test "parses a bare ROM path" {
    const argv = [_][:0]const u8{ "chippy", "game.ch8" };
    const result = try parse(&argv);
    try std.testing.expectEqualStrings("game.ch8", result.rom_path.?);
    try std.testing.expectEqual(false, result.help);
}

test "recognises the help flag" {
    const argv = [_][:0]const u8{ "chippy", "--help" };
    const result = try parse(&argv);
    try std.testing.expectEqual(true, result.help);
    try std.testing.expectEqual(@as(?[:0]const u8, null), result.rom_path);
}

test "rejects a second positional argument" {
    const argv = [_][:0]const u8{ "chippy", "a.ch8", "b.ch8" };
    try std.testing.expectError(error.TooManyPositionalArgs, parse(&argv));
}

test "no args returns an empty parse" {
    const argv = [_][:0]const u8{};
    const result = try parse(&argv);
    try std.testing.expectEqual(@as(?[:0]const u8, null), result.rom_path);
    try std.testing.expectEqual(false, result.help);
}
