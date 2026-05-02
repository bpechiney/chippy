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

    /// Serializes machine state field-by-field rather than via `asBytes`.
    /// Padding bytes inside structs are ABI- and compiler-version-dependent,
    /// so save files written this way survive struct-layout changes when M1+
    /// grows the state. SNES will need this same shape.
    pub fn serialize(self: *const Machine, writer: anytype) !void {
        try writer.writeAll(&self.bus.ram);
        try writer.writeAll(&self.cpu.v);
        try writer.writeInt(u16, self.cpu.i, .big);
        try writer.writeInt(u16, self.cpu.pc, .big);
        try writer.writeInt(u8, self.cpu.sp, .big);
        for (self.cpu.stack) |entry| try writer.writeInt(u16, entry, .big);
        for (self.framebuffer.pixels) |px| try writer.writeInt(u8, px, .big);
        try writer.writeInt(u16, self.keypad.state, .big);
        try writer.writeInt(u8, if (self.keypad.last_released) |k| k else 0xFF, .big);
        try writer.writeInt(u64, self.timing.cycles, .big);
        try writer.writeInt(u8, self.timing.delay_timer, .big);
        try writer.writeInt(u8, self.timing.sound_timer, .big);
    }

    pub fn deserialize(self: *Machine, reader: anytype) !void {
        try reader.readSliceAll(&self.bus.ram);
        try reader.readSliceAll(&self.cpu.v);
        self.cpu.i = try reader.takeInt(u16, .big);
        self.cpu.pc = try reader.takeInt(u16, .big);
        self.cpu.sp = try reader.takeByte();
        for (&self.cpu.stack) |*entry| entry.* = try reader.takeInt(u16, .big);
        for (&self.framebuffer.pixels) |*px| px.* = @intCast(try reader.takeByte());
        self.keypad.state = try reader.takeInt(u16, .big);
        const last = try reader.takeByte();
        self.keypad.last_released = if (last == 0xFF) null else @intCast(last);
        self.timing.cycles = try reader.takeInt(u64, .big);
        self.timing.delay_timer = try reader.takeByte();
        self.timing.sound_timer = try reader.takeByte();
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

test "runUntil returns halted immediately when step halts" {
    var m = Machine.init(.{});
    defer m.deinit();

    const Predicate = struct {
        fn neverDone(_: *const Machine) bool {
            return false;
        }
    };
    try std.testing.expectEqual(StepResult.halted, m.runUntil(Predicate.neverDone));
}

test "runUntil returns ran when the predicate is already satisfied" {
    var m = Machine.init(.{});
    defer m.deinit();

    const Predicate = struct {
        fn alreadyDone(_: *const Machine) bool {
            return true;
        }
    };
    try std.testing.expectEqual(StepResult.ran, m.runUntil(Predicate.alreadyDone));
}

test "deinit is callable on a fresh machine without crashing" {
    var m = Machine.init(.{});
    m.deinit();
}

test "serialize and deserialize roundtrip preserves machine state" {
    var src = Machine.init(.{ .rng_seed = 42 });
    defer src.deinit();
    src.cpu.v[0xA] = 0x55;
    src.cpu.i = 0x300;
    src.cpu.pc = 0x250;
    src.cpu.sp = 3;
    src.cpu.stack[0] = 0x222;
    src.timing.cycles = 1234;
    src.timing.delay_timer = 7;
    src.timing.sound_timer = 9;
    src.keypad.state = 0x00A0;
    src.keypad.last_released = 0xC;
    src.framebuffer.set(10, 5, 1);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.serialize(&aw.writer);

    var dst = Machine.init(.{});
    defer dst.deinit();
    var reader = std.Io.Reader.fixed(aw.written());
    try dst.deserialize(&reader);

    try std.testing.expectEqual(@as(u8, 0x55), dst.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u16, 0x300), dst.cpu.i);
    try std.testing.expectEqual(@as(u16, 0x250), dst.cpu.pc);
    try std.testing.expectEqual(@as(u8, 3), dst.cpu.sp);
    try std.testing.expectEqual(@as(u16, 0x222), dst.cpu.stack[0]);
    try std.testing.expectEqual(@as(Cycles, 1234), dst.timing.cycles);
    try std.testing.expectEqual(@as(u8, 7), dst.timing.delay_timer);
    try std.testing.expectEqual(@as(u8, 9), dst.timing.sound_timer);
    try std.testing.expectEqual(@as(u16, 0x00A0), dst.keypad.state);
    try std.testing.expectEqual(@as(?u4, 0xC), dst.keypad.last_released);
    try std.testing.expectEqual(@as(u1, 1), dst.framebuffer.get(10, 5));
}
