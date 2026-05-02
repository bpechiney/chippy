const std = @import("std");
const bus_mod = @import("bus.zig");
const Bus = bus_mod.Bus;
const Cpu = @import("cpu.zig").Cpu;
const Framebuffer = @import("display.zig").Framebuffer;
const Keypad = @import("keypad.zig").Keypad;
const audio = @import("audio.zig");
const timing_mod = @import("timing.zig");
const Timing = timing_mod.Timing;
const Cycles = timing_mod.Cycles;
const Options = @import("options.zig").Options;
const rom = @import("rom.zig");

pub const StepResult = enum { ran, waiting_for_vblank, halted };

pub const Machine = struct {
    bus: Bus,
    cpu: Cpu,
    framebuffer: Framebuffer,
    keypad: Keypad,
    timing: Timing,
    options: Options,
    prng: std.Random.DefaultPrng,

    pub fn init(opts: Options) Machine {
        return .{
            .bus = Bus.init(),
            .cpu = .{},
            .framebuffer = .{},
            .keypad = .{},
            .timing = .{},
            .options = opts,
            .prng = std.Random.DefaultPrng.init(opts.rng_seed),
        };
    }

    pub fn deinit(self: *Machine) void {
        _ = self;
    }

    pub fn loadRom(self: *Machine, bytes: []const u8) rom.RomError!void {
        try rom.validate(bytes);
        const start = bus_mod.ROM_LOAD_ADDRESS;
        @memcpy(self.bus.ram[start .. start + bytes.len], bytes);
    }

    pub fn step(self: *Machine) StepResult {
        _ = self;
        return .halted;
    }

    pub fn runCycles(self: *Machine, n: u32) Cycles {
        var ran: Cycles = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const result = self.step();
            if (result == .halted) break;
            ran += 1;
            self.timing.cycles += 1;
        }
        return ran;
    }

    pub fn runFrame(self: *Machine) void {
        const cycles_per_frame = self.options.cycles_per_second / 60;
        _ = self.runCycles(cycles_per_frame);
        self.timing.tick();
    }

    pub fn tickTimers(self: *Machine) void {
        self.timing.tick();
    }

    pub fn setKey(self: *Machine, key: u4, down: bool) void {
        self.keypad.setKey(key, down);
    }

    pub fn isBeeping(self: *const Machine) bool {
        return audio.isBeeping(self.timing.sound_timer);
    }

    pub fn runUntil(self: *Machine, predicate: *const fn (*const Machine) bool) StepResult {
        while (!predicate(self)) {
            const result = self.step();
            if (result == .halted) return .halted;
            self.timing.cycles += 1;
        }
        return .ran;
    }

    pub fn serialize(self: *const Machine, writer: anytype) !void {
        try writer.writeAll(&self.bus.ram);
        try writer.writeAll(std.mem.asBytes(&self.cpu));
        try writer.writeAll(&self.framebuffer.pixels);
        try writer.writeAll(std.mem.asBytes(&self.keypad));
        try writer.writeAll(std.mem.asBytes(&self.timing));
    }

    pub fn deserialize(self: *Machine, reader: anytype) !void {
        _ = try reader.readAll(&self.bus.ram);
        _ = try reader.readAll(std.mem.asBytes(&self.cpu));
        _ = try reader.readAll(&self.framebuffer.pixels);
        _ = try reader.readAll(std.mem.asBytes(&self.keypad));
        _ = try reader.readAll(std.mem.asBytes(&self.timing));
    }
};

test "init places PC at the ROM load address and seats the fontset in RAM" {
    var m = Machine.init(.{});
    defer m.deinit();

    try std.testing.expectEqual(@as(u16, 0x200), m.cpu.pc);
    // First byte of the '0' glyph at the start of the fontset.
    try std.testing.expectEqual(@as(u8, 0xF0), m.bus.ram[0x050]);
    // Last byte of the 'F' glyph (0x80) — fontset is 16 glyphs * 5 bytes = 80.
    try std.testing.expectEqual(@as(u8, 0x80), m.bus.ram[0x050 + 79]);
    // Reserved region is zero.
    try std.testing.expectEqual(@as(u8, 0x00), m.bus.ram[0x000]);
    try std.testing.expectEqual(@as(u8, 0x00), m.bus.ram[0x04F]);
}

test "loadRom copies bytes to 0x200 and rejects oversized input" {
    var m = Machine.init(.{});
    defer m.deinit();

    const small_rom = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try m.loadRom(&small_rom);
    try std.testing.expectEqualSlices(u8, &small_rom, m.bus.ram[0x200..0x204]);

    const oversized = [_]u8{0xAA} ** (4096 - 0x200 + 1);
    try std.testing.expectError(error.RomTooLarge, m.loadRom(&oversized));
}

test "step returns halted in M0 (opcodes land at M1)" {
    var m = Machine.init(.{});
    defer m.deinit();
    try std.testing.expectEqual(StepResult.halted, m.step());
}

test "runCycles stops at halted and reports zero cycles ran" {
    var m = Machine.init(.{});
    defer m.deinit();
    const ran = m.runCycles(100);
    try std.testing.expectEqual(@as(Cycles, 0), ran);
    try std.testing.expectEqual(@as(Cycles, 0), m.timing.cycles);
}
