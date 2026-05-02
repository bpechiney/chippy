const std = @import("std");
const Io = std.Io;
const core = @import("chippy_core");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const parsed = try cli.parse(args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (parsed.help) {
        try cli.printUsage(stdout);
        try stdout.flush();
        return;
    }

    const rom_path = parsed.rom_path orelse {
        try stderr.writeAll("error: missing ROM path\n");
        try cli.printUsage(stderr);
        try stderr.flush();
        std.process.exit(2);
    };

    const rom_bytes = try readRom(io, arena, rom_path);

    var m = core.Machine.init(.{});
    defer m.deinit();
    try m.loadRom(rom_bytes);

    try stdout.print("loaded {d} bytes from {s}\n", .{ rom_bytes.len, rom_path });
    try stdout.flush();
}

fn readRom(io: Io, allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.RomFileTooLarge;

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    const n = try file.readPositionalAll(io, buffer, 0);
    if (n != size) return error.UnexpectedEof;

    return buffer;
}

test {
    _ = @import("cli.zig");
}
