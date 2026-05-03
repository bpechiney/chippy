const std = @import("std");
const bus_mod = @import("bus.zig");
const Bus = bus_mod.Bus;
const FONTSET_ADDRESS = bus_mod.FONTSET_ADDRESS;
const FONT_GLYPH_BYTES = bus_mod.FONT_GLYPH_BYTES;
const Cpu = @import("cpu.zig").Cpu;
const Framebuffer = @import("display.zig").Framebuffer;
const Keypad = @import("keypad.zig").Keypad;
const audio = @import("audio.zig");
const timing_mod = @import("timing.zig");
const Timing = timing_mod.Timing;
const Cycles = timing_mod.Cycles;
const Options = @import("options.zig").Options;
const rom = @import("rom.zig");
const assemble = @import("assemble.zig").assemble;
const decode = @import("decode.zig");

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
        const opcode = self.bus.read16(self.cpu.pc);
        self.cpu.pc +%= 2;
        switch (opcode & 0xF000) {
            0x0000 => switch (opcode) {
                0x00E0 => self.framebuffer.clear(),
                0x00EE => {
                    self.cpu.sp -%= 1;
                    self.cpu.pc = self.cpu.stack[self.cpu.sp];
                },
                else => {},
            },
            0x1000 => self.cpu.pc = decode.opNNN(opcode),
            0x2000 => {
                self.cpu.stack[self.cpu.sp] = self.cpu.pc;
                self.cpu.sp +%= 1;
                self.cpu.pc = decode.opNNN(opcode);
            },
            0x3000 => {
                if (self.cpu.v[decode.opX(opcode)] == decode.opNN(opcode)) {
                    self.cpu.pc +%= 2;
                }
            },
            0x4000 => {
                if (self.cpu.v[decode.opX(opcode)] != decode.opNN(opcode)) {
                    self.cpu.pc +%= 2;
                }
            },
            0x5000 => switch (decode.opN(opcode)) {
                0x0 => if (self.cpu.v[decode.opX(opcode)] == self.cpu.v[decode.opY(opcode)]) {
                    self.cpu.pc +%= 2;
                },
                else => {},
            },
            0x6000 => self.cpu.v[decode.opX(opcode)] = decode.opNN(opcode),
            0x7000 => self.cpu.v[decode.opX(opcode)] +%= decode.opNN(opcode),
            0x8000 => {
                const x = decode.opX(opcode);
                const y = decode.opY(opcode);
                switch (decode.opN(opcode)) {
                    0x0 => self.cpu.v[x] = self.cpu.v[y],
                    0x1 => {
                        self.cpu.v[x] |= self.cpu.v[y];
                        // M3: gate on Quirks.vf_reset_on_logical (vanilla = reset; see #38).
                        if (self.options.quirks.vf_reset_on_logical) self.cpu.v[0xF] = 0;
                    },
                    0x2 => {
                        self.cpu.v[x] &= self.cpu.v[y];
                        // M3: gate on Quirks.vf_reset_on_logical (vanilla = reset; see #38).
                        if (self.options.quirks.vf_reset_on_logical) self.cpu.v[0xF] = 0;
                    },
                    0x3 => {
                        self.cpu.v[x] ^= self.cpu.v[y];
                        // M3: gate on Quirks.vf_reset_on_logical (vanilla = reset; see #38).
                        if (self.options.quirks.vf_reset_on_logical) self.cpu.v[0xF] = 0;
                    },
                    0x4 => {
                        const vx = self.cpu.v[x];
                        const vy = self.cpu.v[y];
                        const sum = @addWithOverflow(vx, vy);
                        self.cpu.v[x] = sum[0];
                        self.cpu.v[0xF] = sum[1];
                    },
                    0x5 => {
                        const vx = self.cpu.v[x];
                        const vy = self.cpu.v[y];
                        self.cpu.v[x] = vx -% vy;
                        self.cpu.v[0xF] = @intFromBool(vx >= vy);
                    },
                    0x6 => {
                        // M3: gate on Quirks.shift_in_place (vanilla = shift VY into VX; see #56).
                        const vy = self.cpu.v[y];
                        self.cpu.v[x] = vy >> 1;
                        self.cpu.v[0xF] = vy & 0x01;
                    },
                    0x7 => {
                        const vx = self.cpu.v[x];
                        const vy = self.cpu.v[y];
                        self.cpu.v[x] = vy -% vx;
                        self.cpu.v[0xF] = @intFromBool(vy >= vx);
                    },
                    0xE => {
                        // M3: gate on Quirks.shift_in_place (vanilla = shift VY into VX; see #56).
                        const vy = self.cpu.v[y];
                        self.cpu.v[x] = vy << 1;
                        self.cpu.v[0xF] = (vy >> 7) & 0x01;
                    },
                    else => {},
                }
            },
            0x9000 => switch (decode.opN(opcode)) {
                0x0 => if (self.cpu.v[decode.opX(opcode)] != self.cpu.v[decode.opY(opcode)]) {
                    self.cpu.pc +%= 2;
                },
                else => {},
            },
            0xA000 => self.cpu.i = decode.opNNN(opcode),
            0xB000 => {
                // M3: gate on Quirks.jump_uses_vx (vanilla = V0, not VX; see #56).
                self.cpu.pc = decode.opNNN(opcode) +% self.cpu.v[0x0];
            },
            0xC000 => {
                self.cpu.v[decode.opX(opcode)] = self.prng.random().int(u8) & decode.opNN(opcode);
            },
            0xD000 => {
                const x = self.cpu.v[decode.opX(opcode)];
                const y = self.cpu.v[decode.opY(opcode)];
                const n = decode.opN(opcode);
                var sprite: [15]u8 = undefined;
                for (0..n) |j| sprite[j] = self.bus.read8(self.cpu.i +% @as(u16, @intCast(j)));
                const collided = self.framebuffer.xorSprite(x, y, sprite[0..n]);
                self.cpu.v[0xF] = @intFromBool(collided);
            },
            0xF000 => switch (decode.opNN(opcode)) {
                0x07 => self.cpu.v[decode.opX(opcode)] = self.timing.delay_timer,
                0x15 => self.timing.delay_timer = self.cpu.v[decode.opX(opcode)],
                0x1E => self.cpu.i +%= self.cpu.v[decode.opX(opcode)],
                0x29 => self.cpu.i = FONTSET_ADDRESS + FONT_GLYPH_BYTES * @as(u16, self.cpu.v[decode.opX(opcode)] & 0x0F),
                0x33 => {
                    const vx = self.cpu.v[decode.opX(opcode)];
                    self.bus.write8(self.cpu.i, vx / 100);
                    self.bus.write8(self.cpu.i +% 1, (vx / 10) % 10);
                    self.bus.write8(self.cpu.i +% 2, vx % 10);
                },
                0x55 => {
                    const x = decode.opX(opcode);
                    for (0..@as(usize, x) + 1) |j| {
                        self.bus.write8(self.cpu.i +% @as(u16, @intCast(j)), self.cpu.v[j]);
                    }
                    // M3: gate on Quirks.no_index_increment (vanilla VIP increments I; see #56).
                    self.cpu.i +%= @as(u16, x) + 1;
                },
                0x65 => {
                    const x = decode.opX(opcode);
                    for (0..@as(usize, x) + 1) |j| {
                        self.cpu.v[j] = self.bus.read8(self.cpu.i +% @as(u16, @intCast(j)));
                    }
                    // M3: gate on Quirks.no_index_increment (vanilla VIP increments I; see #56).
                    self.cpu.i +%= @as(u16, x) + 1;
                },
                else => {},
            },
            else => {},
        }
        return .ran;
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
    /// grows the state. The next emulator (Game Boy first) will need this
    /// same shape across MBC / mapper variants.
    pub fn serialize(self: *const Machine, writer: anytype) !void {
        try writer.writeAll(&self.bus.ram);
        try writer.writeAll(&self.cpu.v);
        try writer.writeInt(u16, self.cpu.i, .big);
        try writer.writeInt(u16, self.cpu.pc, .big);
        try writer.writeInt(u8, @as(u8, self.cpu.sp), .big);
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
        self.cpu.sp = @truncate(try reader.takeByte());
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

test "runCycles runs all requested cycles when nothing halts" {
    var m = Machine.init(.{});
    defer m.deinit();
    const ran = m.runCycles(100);
    try std.testing.expectEqual(@as(Cycles, 100), ran);
    try std.testing.expectEqual(@as(Cycles, 100), m.timing.cycles);
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

test "00E0 clears the framebuffer and advances PC by 2" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{0x00E0}));
    m.framebuffer.set(3, 4, 1);
    m.framebuffer.set(63, 31, 1);

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
    for (m.framebuffer.pixels) |px| try std.testing.expectEqual(@as(u1, 0), px);
}

test "1NNN sets PC to NNN" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{0x1456}));

    try std.testing.expectEqual(StepResult.ran, m.step());
    try std.testing.expectEqual(@as(u16, 0x456), m.cpu.pc);
}

test "6XNN loads NN into VX, advances PC, leaves other registers untouched" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x99;
    m.cpu.i = 0x321;
    try m.loadRom(&assemble(.{0x6A42}));

    try std.testing.expectEqual(StepResult.ran, m.step());
    try std.testing.expectEqual(@as(u8, 0x42), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
    try std.testing.expectEqual(@as(u8, 0x99), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u16, 0x321), m.cpu.i);
}

test "7XNN adds NN to VX without touching VF (no wrap)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x5] = 0x10;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x7505}));

    try std.testing.expectEqual(StepResult.ran, m.step());
    try std.testing.expectEqual(@as(u8, 0x15), m.cpu.v[0x5]);
    try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "7XNN wraps at 8 bits without touching VF" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x0] = 0xFF;
    m.cpu.v[0xF] = 0x55;
    try m.loadRom(&assemble(.{0x7001}));

    try std.testing.expectEqual(StepResult.ran, m.step());
    try std.testing.expectEqual(@as(u8, 0x00), m.cpu.v[0x0]);
    try std.testing.expectEqual(@as(u8, 0x55), m.cpu.v[0xF]);
}

test "ANNN loads NNN into I and advances PC" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{0xA789}));

    try std.testing.expectEqual(StepResult.ran, m.step());
    try std.testing.expectEqual(@as(u16, 0x789), m.cpu.i);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "DXYN draws an N-byte sprite at (V[X], V[Y]) from RAM[I] and reports no collision on a clear framebuffer" {
    var m = Machine.init(.{});
    defer m.deinit();
    const sprite = [_]u8{ 0b1010_0011, 0b1100_0000, 0b0000_1111 };
    m.bus.ram[0x300] = sprite[0];
    m.bus.ram[0x301] = sprite[1];
    m.bus.ram[0x302] = sprite[2];
    m.cpu.i = 0x300;
    m.cpu.v[0x2] = 5;
    m.cpu.v[0x3] = 7;
    // Sentinel — the assertion below proves DXYN wrote 0, not that vF was already 0.
    m.cpu.v[0xF] = 0xAA;
    try m.loadRom(&assemble(.{0xD233}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0), m.cpu.v[0xF]);
    const row0 = [_]u1{ 1, 0, 1, 0, 0, 0, 1, 1 };
    const row1 = [_]u1{ 1, 1, 0, 0, 0, 0, 0, 0 };
    const row2 = [_]u1{ 0, 0, 0, 0, 1, 1, 1, 1 };
    for (row0, 0..) |bit, col| try std.testing.expectEqual(bit, m.framebuffer.get(5 + col, 7));
    for (row1, 0..) |bit, col| try std.testing.expectEqual(bit, m.framebuffer.get(5 + col, 8));
    for (row2, 0..) |bit, col| try std.testing.expectEqual(bit, m.framebuffer.get(5 + col, 9));
}

test "DXYN drawing the same sprite twice at the same coords erases it and sets vF == 1" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.bus.ram[0x300] = 0b1111_0000;
    m.cpu.i = 0x300;
    m.cpu.v[0x4] = 10;
    m.cpu.v[0x5] = 12;
    try m.loadRom(&assemble(.{ 0xD451, 0xD451 }));

    _ = m.step();
    _ = m.step();

    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 0), m.framebuffer.get(10 + col, 12));
}

test "DXYN advances PC by 2" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.i = 0x300;
    try m.loadRom(&assemble(.{0xD123}));

    _ = m.step();

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "2NNN pushes PC + 2 onto the return stack and jumps to NNN" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{0x2456}));
    const pre_sp = m.cpu.sp;
    const pre_pc = m.cpu.pc;

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x456), m.cpu.pc);
    try std.testing.expectEqual(pre_sp + 1, m.cpu.sp);
    try std.testing.expectEqual(pre_pc + 2, m.cpu.stack[pre_sp]);
}

test "00EE pops the return stack into PC and decrements sp" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.sp = 1;
    m.cpu.stack[0] = 0x789;
    try m.loadRom(&assemble(.{0x00EE}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x789), m.cpu.pc);
    try std.testing.expectEqual(@as(u4, 0), m.cpu.sp);
}

test "2NNN followed by 00EE returns to the instruction after CALL with sp restored" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{ 0x2204, 0x0000, 0x00EE }));
    const pre_sp = m.cpu.sp;
    const pre_pc = m.cpu.pc;

    _ = m.step();
    _ = m.step();

    try std.testing.expectEqual(pre_pc + 2, m.cpu.pc);
    try std.testing.expectEqual(pre_sp, m.cpu.sp);
}

test "2NNN beyond 16 deep wraps sp at 4 bits rather than panicking the host" {
    // Vanilla COSMAC VIP semantics treat stack overflow as undefined; we follow
    // CLAUDE.md rule 12 and wrap quietly instead of panicking on ROM input.
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{ 0x2202, 0x2202 }));

    var i: usize = 0;
    while (i < 17) : (i += 1) _ = m.step();

    try std.testing.expectEqual(@as(u4, 1), m.cpu.sp);
    try std.testing.expectEqual(@as(u16, 0x204), m.cpu.stack[0]);
}

test "00EE from sp=0 wraps sp at 4 bits rather than panicking the host" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.stack[15] = 0xABC;
    try m.loadRom(&assemble(.{0x00EE}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u4, 15), m.cpu.sp);
    try std.testing.expectEqual(@as(u16, 0xABC), m.cpu.pc);
}

test "3XNN skips the next instruction when VX == NN (PC += 4)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x5] = 0x42;
    try m.loadRom(&assemble(.{0x3542}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x204), m.cpu.pc);
}

test "3XNN does not skip when VX != NN (PC += 2)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x5] = 0x41;
    try m.loadRom(&assemble(.{0x3542}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "4XNN skips the next instruction when VX != NN (PC += 4)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x5] = 0x41;
    try m.loadRom(&assemble(.{0x4542}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x204), m.cpu.pc);
}

test "4XNN does not skip when VX == NN (PC += 2)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x5] = 0x42;
    try m.loadRom(&assemble(.{0x4542}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "5XY0 skips the next instruction when VX == VY (PC += 4)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x77;
    m.cpu.v[0xA] = 0x77;
    try m.loadRom(&assemble(.{0x53A0}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x204), m.cpu.pc);
}

test "5XY0 does not skip when VX != VY (PC += 2)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x77;
    m.cpu.v[0xA] = 0x76;
    try m.loadRom(&assemble(.{0x53A0}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "5XY1 (non-zero low nibble) is a silent no-op that only advances PC" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x77;
    m.cpu.v[0xA] = 0x77;
    try m.loadRom(&assemble(.{0x53A1}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "9XY0 skips the next instruction when VX != VY (PC += 4)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x11;
    m.cpu.v[0xA] = 0x22;
    try m.loadRom(&assemble(.{0x93A0}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x204), m.cpu.pc);
}

test "9XY0 does not skip when VX == VY (PC += 2)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x11;
    m.cpu.v[0xA] = 0x11;
    try m.loadRom(&assemble(.{0x93A0}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "9XY1 (non-zero low nibble) is a silent no-op that only advances PC" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x11;
    m.cpu.v[0xA] = 0x22;
    try m.loadRom(&assemble(.{0x93A1}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY0 copies VY into VX and leaves other registers untouched" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x0] = 0x11;
    m.cpu.v[0x1] = 0x22;
    m.cpu.v[0x3] = 0x33;
    m.cpu.v[0xA] = 0x77;
    m.cpu.v[0xF] = 0xCC;
    try m.loadRom(&assemble(.{0x83A0}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x77), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0x77), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u8, 0x11), m.cpu.v[0x0]);
    try std.testing.expectEqual(@as(u8, 0x22), m.cpu.v[0x1]);
    try std.testing.expectEqual(@as(u8, 0xCC), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY1 ORs VY into VX and resets VF to 0 even when VF was non-zero" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0b1010_0101;
    m.cpu.v[0xA] = 0b0110_1100;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x83A1}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b1110_1101), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0b0110_1100), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u8, 0), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY2 ANDs VY into VX and resets VF to 0 even when VF was non-zero" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0b1010_0101;
    m.cpu.v[0xA] = 0b0110_1100;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x83A2}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b0010_0100), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0b0110_1100), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u8, 0), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY3 XORs VY into VX and resets VF to 0 even when VF was non-zero" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0b1010_0101;
    m.cpu.v[0xA] = 0b0110_1100;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x83A3}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b1100_1001), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0b0110_1100), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u8, 0), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY4 ADDs VY into VX and clears VF when no carry occurs" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x10;
    m.cpu.v[0xA] = 0x05;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x83A4}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x15), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0x05), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u8, 0), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY4 wraps at 8 bits and sets VF=1 on carry" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0xFF;
    m.cpu.v[0xA] = 0x01;
    m.cpu.v[0xF] = 0x00;
    try m.loadRom(&assemble(.{0x83A4}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x00), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY4 with X=0xF stores the carry flag in VF, not the arithmetic result" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0xF] = 0xFF;
    m.cpu.v[0xA] = 0x01;
    try m.loadRom(&assemble(.{0x8FA4}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
}

test "8XY5 SUBs VY from VX and sets VF=1 (no-borrow) when VX >= VY" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x10;
    m.cpu.v[0xA] = 0x05;
    m.cpu.v[0xF] = 0x00;
    try m.loadRom(&assemble(.{0x83A5}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x0B), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0x05), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY5 wraps at 8 bits and sets VF=0 (borrow) when VX < VY" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x00;
    m.cpu.v[0xA] = 0x01;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x83A5}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0xFF), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY5 with X=0xF stores the no-borrow flag in VF, not the arithmetic result" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0xF] = 0x10;
    m.cpu.v[0xA] = 0x05;
    try m.loadRom(&assemble(.{0x8FA5}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
}

test "8XY7 stores VY-VX in VX and sets VF=1 (no-borrow) when VY >= VX" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x05;
    m.cpu.v[0xA] = 0x10;
    m.cpu.v[0xF] = 0x00;
    try m.loadRom(&assemble(.{0x83A7}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x0B), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0x10), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY7 wraps at 8 bits and sets VF=0 (borrow) when VY < VX" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x01;
    m.cpu.v[0xA] = 0x00;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x83A7}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0xFF), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY7 with X=0xF stores the no-borrow flag in VF, not the arithmetic result" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0xF] = 0x05;
    m.cpu.v[0xA] = 0x10;
    try m.loadRom(&assemble(.{0x8FA7}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
}

test "8XY6 SHRs VY into VX and stores the popped LSB (0) in VF" {
    var m = Machine.init(.{});
    defer m.deinit();
    // VX != VY before the step distinguishes vanilla VIP semantics from the
    // M3 shift-in-place quirk — if shift_in_place were prematurely wired,
    // VX would shift its own value (0xAB >> 1 = 0x55), not VY's.
    m.cpu.v[0x3] = 0xAB;
    m.cpu.v[0xA] = 0b1100_1010;
    m.cpu.v[0xF] = 0xCD;
    try m.loadRom(&assemble(.{0x83A6}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b0110_0101), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0b1100_1010), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u8, 0), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY6 SHRs VY into VX and stores the popped LSB (1) in VF" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0xAB;
    m.cpu.v[0xA] = 0b1100_1011;
    m.cpu.v[0xF] = 0x00;
    try m.loadRom(&assemble(.{0x83A6}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b0110_0101), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XY6 with X=0xF stores the popped LSB in VF, not the shifted byte" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0xF] = 0x00;
    m.cpu.v[0xA] = 0b1100_1011;
    try m.loadRom(&assemble(.{0x8FA6}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
}

test "8XYE SHLs VY into VX and stores the popped MSB (0) in VF" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0xAB;
    m.cpu.v[0xA] = 0b0101_0011;
    m.cpu.v[0xF] = 0xCD;
    try m.loadRom(&assemble(.{0x83AE}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b1010_0110), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0b0101_0011), m.cpu.v[0xA]);
    try std.testing.expectEqual(@as(u8, 0), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XYE SHLs VY into VX and stores the popped MSB (1) in VF" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0xAB;
    m.cpu.v[0xA] = 0b1100_1010;
    m.cpu.v[0xF] = 0x00;
    try m.loadRom(&assemble(.{0x83AE}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b1001_0100), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "8XYE with X=0xF stores the popped MSB in VF, not the shifted byte" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0xF] = 0x00;
    m.cpu.v[0xA] = 0b1100_1010;
    try m.loadRom(&assemble(.{0x8FAE}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 1), m.cpu.v[0xF]);
}

test "8XYN with non-canonical low nibble is a silent no-op that only advances PC" {
    // 0x8 / 0x9 / 0xA / 0xB / 0xC / 0xD / 0xF are not vanilla 8XYN ops at M2 —
    // 8XY4-8XY7 and 8XYE land in M2.5/M2.6, but 8XY8/9/A/B/C/D/F never become
    // canonical encodings in the vanilla VIP ISA. ROMs containing them must
    // not panic the host (CLAUDE.md rule 12) and must not perturb V or VF.
    const non_canonical = [_]u16{ 0x83A8, 0x83A9, 0x83AA, 0x83AB, 0x83AC, 0x83AD, 0x83AF };
    inline for (non_canonical) |op| {
        var m = Machine.init(.{});
        defer m.deinit();
        m.cpu.v[0x3] = 0xAB;
        m.cpu.v[0xA] = 0xCD;
        m.cpu.v[0xF] = 0xEF;
        try m.loadRom(&assemble(.{op}));

        try std.testing.expectEqual(StepResult.ran, m.step());

        try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.v[0x3]);
        try std.testing.expectEqual(@as(u8, 0xCD), m.cpu.v[0xA]);
        try std.testing.expectEqual(@as(u8, 0xEF), m.cpu.v[0xF]);
        try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
    }
}

test "BNNN sets PC to NNN + V0 (vanilla VIP — V0, not VX)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x0] = 0x05;
    try m.loadRom(&assemble(.{0xB456}));

    try std.testing.expectEqual(StepResult.ran, m.step());
    try std.testing.expectEqual(@as(u16, 0x45B), m.cpu.pc);
}

test "BNNN with VX != V0 takes the vanilla path (uses V0, ignores VX)" {
    // Encoded as 0xBA56 — vanilla reads NNN as the full 12 low bits (0xA56)
    // and adds V0 (= 0x05) for PC = 0xA5B. The M3 jump_uses_vx quirk would
    // instead add V[A] (= 0x77) for PC = 0xACD. Setting V0 != V[A] makes the
    // assertion sensitive to which register was selected.
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x0] = 0x05;
    m.cpu.v[0xA] = 0x77;
    try m.loadRom(&assemble(.{0xBA56}));

    try std.testing.expectEqual(StepResult.ran, m.step());
    try std.testing.expectEqual(@as(u16, 0xA5B), m.cpu.pc);
}

test "CXNN with NN=0xFF emits the deterministic prng byte stream for the seeded prng" {
    // Cross-runner determinism gate for CXNN: with `Options.rng_seed` fixed,
    // the four sourced bytes must match exactly on every host. The expected
    // values were captured once locally from std.Random.DefaultPrng
    // (Xoshiro256) seeded with 0xDEADBEEFCAFEBABE — algorithm is platform-
    // independent, so the expectations are inlined directly.
    var m = Machine.init(.{ .rng_seed = 0xDEADBEEFCAFEBABE });
    defer m.deinit();
    try m.loadRom(&assemble(.{ 0xC1FF, 0xC2FF, 0xC3FF, 0xC4FF }));

    _ = m.step();
    _ = m.step();
    _ = m.step();
    _ = m.step();

    try std.testing.expectEqual(@as(u8, 0xE0), m.cpu.v[0x1]);
    try std.testing.expectEqual(@as(u8, 0xC3), m.cpu.v[0x2]);
    try std.testing.expectEqual(@as(u8, 0x44), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0x18), m.cpu.v[0x4]);
}

test "CXNN ANDs the random byte with NN (high nibble cleared when NN=0x0F)" {
    // First two seeded bytes are 0xE0, 0xC3 (see deterministic-stream test
    // above). The first 0xC?FF burns 0xE0; the 0xC50F then masks 0xC3 with
    // 0x0F → 0x03. That non-trivial result distinguishes a real mask from
    // mutations that always produce zero — the obvious `0xE0 & 0x0F = 0x00`
    // test would pass even if the mask were dropped to `& 0`.
    var m = Machine.init(.{ .rng_seed = 0xDEADBEEFCAFEBABE });
    defer m.deinit();
    try m.loadRom(&assemble(.{ 0xC1FF, 0xC50F }));

    _ = m.step();
    _ = m.step();

    try std.testing.expectEqual(@as(u8, 0x03), m.cpu.v[0x5]);
}

test "0NNN (non-00E0) is a silent no-op that only advances PC" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{0x0123}));
    m.framebuffer.set(10, 5, 1);

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
    try std.testing.expectEqual(@as(u1, 1), m.framebuffer.get(10, 5));
}

test "FX07 loads the delay timer into VX" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.timing.delay_timer = 42;
    m.cpu.v[0x3] = 0xAB;
    try m.loadRom(&assemble(.{0xF307}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 42), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 42), m.timing.delay_timer);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "FX15 stores VX into the delay timer" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 99;
    m.timing.delay_timer = 0;
    try m.loadRom(&assemble(.{0xF315}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 99), m.timing.delay_timer);
    try std.testing.expectEqual(@as(u8, 99), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "FX15 then tickTimers then FX07 observes the 60 Hz decrement through the ROM-visible interface" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 5;
    try m.loadRom(&assemble(.{ 0xF315, 0xF407 }));

    _ = m.step();
    m.tickTimers();
    _ = m.step();

    try std.testing.expectEqual(@as(u8, 4), m.cpu.v[0x4]);
    try std.testing.expectEqual(@as(u8, 4), m.timing.delay_timer);
}

test "FX1E adds VX to I without wrap and leaves VF untouched" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.i = 0x300;
    m.cpu.v[0x3] = 0x05;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0xF31E}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x305), m.cpu.i);
    try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.v[0xF]);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "FX1E wraps I at 16 bits and leaves VF untouched (vanilla VIP — no carry write)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.i = 0xFFFF;
    m.cpu.v[0x3] = 0x01;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0xF31E}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x0000), m.cpu.i);
    try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.v[0xF]);
}

test "FX29 points I at the 5-byte fontset glyph for each hex digit 0..F" {
    // Expected glyph bytes mirror the FONTSET table in bus.zig — the test
    // catches both an incorrect base address and an incorrect stride.
    const glyphs = [16][5]u8{
        .{ 0xF0, 0x90, 0x90, 0x90, 0xF0 }, // 0
        .{ 0x20, 0x60, 0x20, 0x20, 0x70 }, // 1
        .{ 0xF0, 0x10, 0xF0, 0x80, 0xF0 }, // 2
        .{ 0xF0, 0x10, 0xF0, 0x10, 0xF0 }, // 3
        .{ 0x90, 0x90, 0xF0, 0x10, 0x10 }, // 4
        .{ 0xF0, 0x80, 0xF0, 0x10, 0xF0 }, // 5
        .{ 0xF0, 0x80, 0xF0, 0x90, 0xF0 }, // 6
        .{ 0xF0, 0x10, 0x20, 0x40, 0x40 }, // 7
        .{ 0xF0, 0x90, 0xF0, 0x90, 0xF0 }, // 8
        .{ 0xF0, 0x90, 0xF0, 0x10, 0xF0 }, // 9
        .{ 0xF0, 0x90, 0xF0, 0x90, 0x90 }, // A
        .{ 0xE0, 0x90, 0xE0, 0x90, 0xE0 }, // B
        .{ 0xF0, 0x80, 0x80, 0x80, 0xF0 }, // C
        .{ 0xE0, 0x90, 0x90, 0x90, 0xE0 }, // D
        .{ 0xF0, 0x80, 0xF0, 0x80, 0xF0 }, // E
        .{ 0xF0, 0x80, 0xF0, 0x80, 0x80 }, // F
    };
    for (glyphs, 0..) |expected, digit| {
        var m = Machine.init(.{});
        defer m.deinit();
        m.cpu.v[0x3] = @intCast(digit);
        try m.loadRom(&assemble(.{0xF329}));

        try std.testing.expectEqual(StepResult.ran, m.step());

        try std.testing.expectEqualSlices(u8, &expected, m.bus.ram[m.cpu.i .. m.cpu.i + FONT_GLYPH_BYTES]);
    }
}

test "FX18 falls through silently — advances PC, leaves V/I/timers untouched (sound timer set lands in M5)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x77;
    m.cpu.i = 0x321;
    m.timing.sound_timer = 0xAA;
    m.timing.delay_timer = 0xBB;
    try m.loadRom(&assemble(.{0xF318}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
    try std.testing.expectEqual(@as(u8, 0x77), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u16, 0x321), m.cpu.i);
    try std.testing.expectEqual(@as(u8, 0xAA), m.timing.sound_timer);
    try std.testing.expectEqual(@as(u8, 0xBB), m.timing.delay_timer);
}

test "FX29 ignores the high nibble of VX (digit selected from low 4 bits only)" {
    // VX = 0xA5 → glyph index 0x5; without the mask the index would walk past
    // the end of the fontset and pick up arbitrary RAM.
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0xA5;
    try m.loadRom(&assemble(.{0xF329}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    const expected = [_]u8{ 0xF0, 0x80, 0xF0, 0x10, 0xF0 };
    try std.testing.expectEqualSlices(u8, &expected, m.bus.ram[m.cpu.i .. m.cpu.i + FONT_GLYPH_BYTES]);
}

test "serialize and deserialize roundtrip preserves a live IBM-logo framebuffer" {
    // The hand-set roundtrip test below already covers all 11 fields. This
    // test's value is proving the same discipline survives live DXYN-produced
    // state — the next emulator (Game Boy first, per ADR 0010) will hit this
    // pattern against MBC/mapper variants.
    const cwd = std.Io.Dir.cwd();
    const io = std.testing.io;
    const rom_bytes = try cwd.readFileAlloc(io, "tests/test_roms/ibm_logo.ch8", std.testing.allocator, .limited(bus_mod.ROM_MAX_BYTES));
    defer std.testing.allocator.free(rom_bytes);

    var src = Machine.init(.{});
    defer src.deinit();
    try src.loadRom(rom_bytes);
    _ = src.runCycles(30);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.serialize(&aw.writer);

    var dst = Machine.init(.{});
    defer dst.deinit();
    var reader = std.Io.Reader.fixed(aw.written());
    try dst.deserialize(&reader);

    try std.testing.expectEqualSlices(u1, &src.framebuffer.pixels, &dst.framebuffer.pixels);
}

test "serialize and deserialize roundtrip preserves machine state set by M2.8/M2.9 timer/I/store opcodes" {
    // delay_timer, I, and the FX55-written RAM bytes are populated via the
    // ROM-visible interface rather than hand-set so the roundtrip is exercised
    // against state the ROM actually produces.
    var src = Machine.init(.{ .rng_seed = 42 });
    defer src.deinit();
    src.cpu.v[0x0] = 0xC0;
    src.cpu.v[0x1] = 0xC1;
    src.cpu.v[0x2] = 0xC2;
    src.cpu.v[0xA] = 0x55;
    src.cpu.v[0x3] = 7;
    src.cpu.v[0x4] = 0x05;
    src.cpu.i = 0x300;
    try src.loadRom(&assemble(.{ 0xF315, 0xF41E, 0xF255, 0x2456 }));
    _ = src.step();
    _ = src.step();
    _ = src.step();
    _ = src.step();
    src.timing.cycles = 1234;
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
    try std.testing.expectEqual(@as(u16, 0x308), dst.cpu.i);
    try std.testing.expectEqual(@as(u8, 0xC0), dst.bus.ram[0x305]);
    try std.testing.expectEqual(@as(u8, 0xC1), dst.bus.ram[0x306]);
    try std.testing.expectEqual(@as(u8, 0xC2), dst.bus.ram[0x307]);
    try std.testing.expectEqual(@as(u16, 0x456), dst.cpu.pc);
    try std.testing.expectEqual(@as(u4, 1), dst.cpu.sp);
    try std.testing.expectEqual(@as(u16, 0x208), dst.cpu.stack[0]);
    try std.testing.expectEqual(@as(Cycles, 1234), dst.timing.cycles);
    try std.testing.expectEqual(@as(u8, 7), dst.timing.delay_timer);
    try std.testing.expectEqual(@as(u8, 9), dst.timing.sound_timer);
    try std.testing.expectEqual(@as(u16, 0x00A0), dst.keypad.state);
    try std.testing.expectEqual(@as(?u4, 0xC), dst.keypad.last_released);
    try std.testing.expectEqual(@as(u1, 1), dst.framebuffer.get(10, 5));
}

test "FX33 writes hundreds, tens, units of VX (123) into RAM[I], RAM[I+1], RAM[I+2]" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 123;
    m.cpu.i = 0x300;
    try m.loadRom(&assemble(.{0xF333}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 1), m.bus.ram[0x300]);
    try std.testing.expectEqual(@as(u8, 2), m.bus.ram[0x301]);
    try std.testing.expectEqual(@as(u8, 3), m.bus.ram[0x302]);
    try std.testing.expectEqual(@as(u16, 0x300), m.cpu.i);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "FX33 writes (2, 5, 5) for VX=255 — max u8 boundary" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 255;
    m.cpu.i = 0x300;
    try m.loadRom(&assemble(.{0xF333}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 2), m.bus.ram[0x300]);
    try std.testing.expectEqual(@as(u8, 5), m.bus.ram[0x301]);
    try std.testing.expectEqual(@as(u8, 5), m.bus.ram[0x302]);
}

test "FX33 writes (0, 0, 0) for VX=0" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0;
    m.cpu.i = 0x300;
    m.bus.ram[0x300] = 0xAA;
    m.bus.ram[0x301] = 0xBB;
    m.bus.ram[0x302] = 0xCC;
    try m.loadRom(&assemble(.{0xF333}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0), m.bus.ram[0x300]);
    try std.testing.expectEqual(@as(u8, 0), m.bus.ram[0x301]);
    try std.testing.expectEqual(@as(u8, 0), m.bus.ram[0x302]);
}

test "FX55 with X=0 writes only V0 to RAM[I] and increments I by 1 (vanilla VIP)" {
    // Sentinel at RAM[I+1] proves the bulk-store stops at X (inclusive) — if
    // it ran one byte too far, RAM[I+1] would be overwritten with V1.
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x0] = 0x42;
    m.cpu.v[0x1] = 0x99;
    m.cpu.i = 0x300;
    m.bus.ram[0x301] = 0xAA;
    try m.loadRom(&assemble(.{0xF055}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x42), m.bus.ram[0x300]);
    try std.testing.expectEqual(@as(u8, 0xAA), m.bus.ram[0x301]);
    try std.testing.expectEqual(@as(u16, 0x301), m.cpu.i);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "FX55 with X=15 stores V0..VF to RAM[I..I+15] and increments I by 16 (vanilla VIP)" {
    var m = Machine.init(.{});
    defer m.deinit();
    for (0..16) |j| m.cpu.v[j] = @as(u8, @intCast(j)) +% 0xA0;
    m.cpu.i = 0x300;
    try m.loadRom(&assemble(.{0xFF55}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    for (0..16) |j| {
        try std.testing.expectEqual(@as(u8, @intCast(j)) +% 0xA0, m.bus.ram[0x300 + j]);
    }
    try std.testing.expectEqual(@as(u16, 0x310), m.cpu.i);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "FX65 with X=0 loads V0 from RAM[I] and increments I by 1 (vanilla VIP)" {
    // Sentinel at V1 proves the bulk-load stops at X (inclusive) — if it ran
    // one register too far, V1 would be clobbered with RAM[I+1].
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x0] = 0x99;
    m.cpu.v[0x1] = 0x77;
    m.cpu.i = 0x300;
    m.bus.ram[0x300] = 0x42;
    m.bus.ram[0x301] = 0xBB;
    try m.loadRom(&assemble(.{0xF065}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x42), m.cpu.v[0x0]);
    try std.testing.expectEqual(@as(u8, 0x77), m.cpu.v[0x1]);
    try std.testing.expectEqual(@as(u16, 0x301), m.cpu.i);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "FX65 with X=15 loads V0..VF from RAM[I..I+15] and increments I by 16 (vanilla VIP)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.i = 0x300;
    for (0..16) |j| m.bus.ram[0x300 + j] = @as(u8, @intCast(j)) +% 0xA0;
    try m.loadRom(&assemble(.{0xFF65}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    for (0..16) |j| {
        try std.testing.expectEqual(@as(u8, @intCast(j)) +% 0xA0, m.cpu.v[j]);
    }
    try std.testing.expectEqual(@as(u16, 0x310), m.cpu.i);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "FX55 with I past 0xFFF wraps RAM addressing at 12 bits rather than panicking the host" {
    // ROMs that set I high before a bulk store would index past ram[4095] if
    // the new opcode bypassed the bus mask — same rule-12 invariant DXYN
    // already relies on (see FX1E wrap test and Bus.read8 mask).
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x0] = 0x42;
    m.cpu.v[0x1] = 0x77;
    m.cpu.i = 0xFFFE;
    try m.loadRom(&assemble(.{0xF155}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x42), m.bus.ram[0xFFE]);
    try std.testing.expectEqual(@as(u8, 0x77), m.bus.ram[0xFFF]);
    try std.testing.expectEqual(@as(u16, 0x0000), m.cpu.i);
}

test "FX65 with I past 0xFFF wraps RAM addressing at 12 bits rather than panicking the host" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.bus.ram[0xFFE] = 0x42;
    m.bus.ram[0xFFF] = 0x77;
    m.cpu.i = 0xFFFE;
    try m.loadRom(&assemble(.{0xF165}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x42), m.cpu.v[0x0]);
    try std.testing.expectEqual(@as(u8, 0x77), m.cpu.v[0x1]);
    try std.testing.expectEqual(@as(u16, 0x0000), m.cpu.i);
}
