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
const trace_mod = @import("trace.zig");

pub const StepResult = enum { ran, waiting_for_vblank, waiting_for_key, halted };

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

    /// Test-only intervention: lets external-ROM golden tests set in-RAM
    /// control bytes the ROM expects pre-boot (e.g. Timendus's 5-quirks.ch8
    /// reads `RAM[0x1FF]` to pick a platform). Provides the abstraction
    /// boundary the Game Boy-bound bus-private refactor will preserve.
    pub fn pokeRam(self: *Machine, addr: u12, byte: u8) void {
        self.bus.ram[addr] = byte;
    }

    pub fn step(self: *Machine) StepResult {
        const opcode = self.bus.read16(self.cpu.pc);
        if (self.shouldStallForVblank(opcode)) return .waiting_for_vblank;
        const pre_pc = self.cpu.pc;
        self.cpu.pc +%= 2;
        // Threaded into emitTrace so DRW VF, ... renders the pre-step coord
        // value instead of the post-step collision flag.
        var draw: ?trace_mod.DrawOutcome = null;
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
                        if (self.options.quirks.vf_reset_on_logical) self.cpu.v[0xF] = 0;
                    },
                    0x2 => {
                        self.cpu.v[x] &= self.cpu.v[y];
                        if (self.options.quirks.vf_reset_on_logical) self.cpu.v[0xF] = 0;
                    },
                    0x3 => {
                        self.cpu.v[x] ^= self.cpu.v[y];
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
                        const src = if (self.options.quirks.shift_in_place) self.cpu.v[x] else self.cpu.v[y];
                        self.cpu.v[x] = src >> 1;
                        self.cpu.v[0xF] = src & 0x01;
                    },
                    0x7 => {
                        const vx = self.cpu.v[x];
                        const vy = self.cpu.v[y];
                        self.cpu.v[x] = vy -% vx;
                        self.cpu.v[0xF] = @intFromBool(vy >= vx);
                    },
                    0xE => {
                        const src = if (self.options.quirks.shift_in_place) self.cpu.v[x] else self.cpu.v[y];
                        self.cpu.v[x] = src << 1;
                        self.cpu.v[0xF] = (src >> 7) & 0x01;
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
                const reg = if (self.options.quirks.jump_uses_vx) decode.opX(opcode) else 0x0;
                self.cpu.pc = decode.opNNN(opcode) +% self.cpu.v[reg];
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
                // Quirk-flag inversion: vanilla VIP clips (display_clipping = true ⇒ wrap = false).
                const collided = self.framebuffer.xorSprite(x, y, sprite[0..n], !self.options.quirks.display_clipping);
                self.cpu.v[0xF] = @intFromBool(collided);
                self.emitSpriteLog(x, y, n, collided);
                draw = .{ .x = x, .y = y, .n = n, .collision = collided };
            },
            0xE000 => switch (decode.opNN(opcode)) {
                0x9E => if (self.keypad.isDown(@truncate(self.cpu.v[decode.opX(opcode)]))) {
                    self.cpu.pc +%= 2;
                },
                0xA1 => if (!self.keypad.isDown(@truncate(self.cpu.v[decode.opX(opcode)]))) {
                    self.cpu.pc +%= 2;
                },
                else => {},
            },
            0xF000 => switch (decode.opNN(opcode)) {
                0x07 => self.cpu.v[decode.opX(opcode)] = self.timing.delay_timer,
                // Re-fetches next cycle on stall (no PC advance, no trace) — see ADR 0013.
                0x0A => {
                    if (self.keypad.pollAwaitedKey()) |key| {
                        self.cpu.v[decode.opX(opcode)] = key;
                    } else {
                        self.cpu.pc = pre_pc;
                        return .waiting_for_key;
                    }
                },
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
                    if (!self.options.quirks.no_index_increment) self.cpu.i +%= @as(u16, x) + 1;
                },
                0x65 => {
                    const x = decode.opX(opcode);
                    for (0..@as(usize, x) + 1) |j| {
                        self.cpu.v[j] = self.bus.read8(self.cpu.i +% @as(u16, @intCast(j)));
                    }
                    if (!self.options.quirks.no_index_increment) self.cpu.i +%= @as(u16, x) + 1;
                },
                else => {},
            },
            else => {},
        }
        self.emitTrace(pre_pc, opcode, draw);
        return .ran;
    }

    /// Vanilla VIP `DXYN` stalls the CPU until the next 60 Hz tick before
    /// drawing — see ADR 0012 for the contract change to `step()` / `runCycles`
    /// this introduces. Frame boundary is `cycles % cycles_per_frame == 0`,
    /// matching `runFrame`'s already-shipped budget.
    fn shouldStallForVblank(self: *const Machine, opcode: u16) bool {
        if (!self.options.quirks.vblank_wait_on_draw) return false;
        if ((opcode & 0xF000) != 0xD000) return false;
        const cycles_per_frame = self.options.cycles_per_second / 60;
        return self.timing.cycles % cycles_per_frame != 0;
    }

    fn emitTrace(self: *const Machine, pre_pc: u16, opcode: u16, draw: ?trace_mod.DrawOutcome) void {
        const sink = self.options.trace orelse return;
        // 128 bytes is sized for the longest line the M2.10 token set produces,
        // with headroom for future state-delta tokens. A buffer overflow here
        // would be a chippy bug, not ROM input — fail-open and skip the line.
        var buf: [128]u8 = undefined;
        const line = trace_mod.formatTraceLine(&buf, pre_pc, opcode, .{
            .cpu = &self.cpu,
            .delay_timer = self.timing.delay_timer,
            .draw = draw,
        }) catch return;
        sink.write(sink.ctx, line);
    }

    fn emitSpriteLog(self: *const Machine, x: u8, y: u8, n: u4, collision: bool) void {
        const sink = self.options.sprite_log orelse return;
        // Sized like emitTrace's buffer; same fail-open rationale.
        var buf: [64]u8 = undefined;
        const line = trace_mod.formatSpriteLog(&buf, self.timing.cycles, x, y, n, collision) catch return;
        sink.write(sink.ctx, line);
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

    /// FX0A has no internal wakeup so `.waiting_for_key` must yield to the
    /// driver; `.waiting_for_vblank` does not, since the next cycle boundary
    /// unblocks it. See ADR 0013.
    pub fn runUntil(self: *Machine, predicate: *const fn (*const Machine) bool) StepResult {
        while (!predicate(self)) {
            const result = self.step();
            switch (result) {
                .halted, .waiting_for_key => return result,
                .ran, .waiting_for_vblank => self.timing.cycles += 1,
            }
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
        try self.keypad.serialize(writer);
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
        self.keypad = try Keypad.deserialize(reader);
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

test "pokeRam writes the given byte at the given address" {
    var m = Machine.init(.{});
    defer m.deinit();

    m.pokeRam(0x1FF, 1);
    try std.testing.expectEqual(@as(u8, 1), m.bus.ram[0x1FF]);
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

test "DXYN: vblank_wait_on_draw=true off frame boundary stalls and preserves PC + framebuffer" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.bus.ram[0x300] = 0xFF;
    m.cpu.i = 0x300;
    try m.loadRom(&assemble(.{0xD001}));
    m.timing.cycles = 1; // cycles_per_frame = 700/60 = 11; 1 % 11 != 0

    const result = m.step();

    try std.testing.expectEqual(StepResult.waiting_for_vblank, result);
    try std.testing.expectEqual(@as(u16, 0x200), m.cpu.pc);
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 0), m.framebuffer.get(col, 0));
}

test "DXYN: vblank_wait_on_draw=true on frame boundary executes immediately" {
    // Cycle 0 is a frame boundary (0 % 11 == 0). DXYN executes on the spot.
    var m = Machine.init(.{});
    defer m.deinit();
    m.bus.ram[0x300] = 0xFF;
    m.cpu.i = 0x300;
    try m.loadRom(&assemble(.{0xD001}));

    const result = m.step();

    try std.testing.expectEqual(StepResult.ran, result);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 1), m.framebuffer.get(col, 0));
}

test "DXYN: vblank_wait_on_draw=false executes off frame boundary" {
    var m = Machine.init(.{ .quirks = .{ .vblank_wait_on_draw = false } });
    defer m.deinit();
    m.bus.ram[0x300] = 0xFF;
    m.cpu.i = 0x300;
    try m.loadRom(&assemble(.{0xD001}));
    m.timing.cycles = 1; // not on boundary; quirk-off path ignores it

    const result = m.step();

    try std.testing.expectEqual(StepResult.ran, result);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 1), m.framebuffer.get(col, 0));
}

test "runCycles: vblank_wait_on_draw=true burns stall cycles until DXYN reaches frame boundary" {
    // DXYN fetched at cycle 1 stalls until cycle 11; runCycles advances
    // timing.cycles on each stall iteration so the same DXYN re-fetches and
    // eventually executes when the boundary is reached.
    var m = Machine.init(.{});
    defer m.deinit();
    m.bus.ram[0x300] = 0xFF;
    m.cpu.i = 0x300;
    try m.loadRom(&assemble(.{0xD001}));
    m.timing.cycles = 1;

    const ran = m.runCycles(11);

    try std.testing.expectEqual(@as(u64, 11), ran);
    try std.testing.expectEqual(@as(u64, 12), m.timing.cycles);
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 1), m.framebuffer.get(col, 0));
}

test "DXYN: display_clipping=false wraps overflowing pixels around the right edge" {
    var m = Machine.init(.{ .quirks = .{ .display_clipping = false } });
    defer m.deinit();
    m.bus.ram[0x300] = 0xFF;
    m.cpu.i = 0x300;
    m.cpu.v[0x2] = 60;
    m.cpu.v[0x3] = 0;
    try m.loadRom(&assemble(.{0xD231}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    for (60..64) |col| try std.testing.expectEqual(@as(u1, 1), m.framebuffer.get(col, 0));
    for (0..4) |col| try std.testing.expectEqual(@as(u1, 1), m.framebuffer.get(col, 0));
    for (4..60) |col| try std.testing.expectEqual(@as(u1, 0), m.framebuffer.get(col, 0));
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

test "EX9E VX: skip when key VX is down (PC += 4)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x0] = 0x05;
    try m.loadRom(&assemble(.{0xE09E}));
    m.setKey(0x5, true);

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x204), m.cpu.pc);
}

test "EX9E VX: no-skip when key VX is up (PC += 2)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x0] = 0x05;
    try m.loadRom(&assemble(.{0xE09E}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "EXA1 VX: skip when key VX is up (PC += 4)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x07;
    try m.loadRom(&assemble(.{0xE3A1}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x204), m.cpu.pc);
}

test "EXA1 VX: no-skip when key VX is down (PC += 2)" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x3] = 0x07;
    try m.loadRom(&assemble(.{0xE3A1}));
    m.setKey(0x7, true);

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "EX9E VX: high nibble of VX is masked off — only low nibble selects the key" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x2] = 0xA5;
    try m.loadRom(&assemble(.{0xE29E}));
    m.setKey(0x5, true);

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x204), m.cpu.pc);
}

test "EXA1 VX: high nibble of VX is masked off — only low nibble selects the key" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x2] = 0xF5;
    try m.loadRom(&assemble(.{0xE2A1}));
    m.setKey(0x5, true);

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

test "8XY1: vf_reset_on_logical=false leaves VF unchanged after OR" {
    var m = Machine.init(.{ .quirks = .{ .vf_reset_on_logical = false } });
    defer m.deinit();
    m.cpu.v[0x3] = 0b1010_0101;
    m.cpu.v[0xA] = 0b0110_1100;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x83A1}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b1110_1101), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.v[0xF]);
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

test "8XY2: vf_reset_on_logical=false leaves VF unchanged after AND" {
    var m = Machine.init(.{ .quirks = .{ .vf_reset_on_logical = false } });
    defer m.deinit();
    m.cpu.v[0x3] = 0b1010_0101;
    m.cpu.v[0xA] = 0b0110_1100;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x83A2}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b0010_0100), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.v[0xF]);
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

test "8XY3: vf_reset_on_logical=false leaves VF unchanged after XOR" {
    var m = Machine.init(.{ .quirks = .{ .vf_reset_on_logical = false } });
    defer m.deinit();
    m.cpu.v[0x3] = 0b1010_0101;
    m.cpu.v[0xA] = 0b0110_1100;
    m.cpu.v[0xF] = 0xAB;
    try m.loadRom(&assemble(.{0x83A3}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0b1100_1001), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.v[0xF]);
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

test "8XY6: shift_in_place=true SHRs VX in place and ignores VY" {
    var m = Machine.init(.{ .quirks = .{ .shift_in_place = true } });
    defer m.deinit();
    m.cpu.v[0x3] = 0xAB;
    m.cpu.v[0xA] = 0b1100_1010;
    m.cpu.v[0xF] = 0xCD;
    try m.loadRom(&assemble(.{0x83A6}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x55), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0b1100_1010), m.cpu.v[0xA]);
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

test "8XYE: shift_in_place=true SHLs VX in place and ignores VY" {
    var m = Machine.init(.{ .quirks = .{ .shift_in_place = true } });
    defer m.deinit();
    m.cpu.v[0x3] = 0xAB;
    m.cpu.v[0xA] = 0b0101_0011;
    m.cpu.v[0xF] = 0xCD;
    try m.loadRom(&assemble(.{0x83AE}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u8, 0x56), m.cpu.v[0x3]);
    try std.testing.expectEqual(@as(u8, 0b0101_0011), m.cpu.v[0xA]);
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

test "BNNN: jump_uses_vx=true reads V[high nibble of NNN] and ignores V0" {
    var m = Machine.init(.{ .quirks = .{ .jump_uses_vx = true } });
    defer m.deinit();
    m.cpu.v[0x0] = 0x05;
    m.cpu.v[0xA] = 0x77;
    try m.loadRom(&assemble(.{0xBA56}));

    try std.testing.expectEqual(StepResult.ran, m.step());
    try std.testing.expectEqual(@as(u16, 0xACD), m.cpu.pc);
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

test "FX0A phase 1: no key held returns waiting_for_key with PC unchanged across iterations" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x5] = 0xAB;
    try m.loadRom(&assemble(.{0xF50A}));

    try std.testing.expectEqual(StepResult.waiting_for_key, m.step());
    try std.testing.expectEqual(StepResult.waiting_for_key, m.step());

    try std.testing.expectEqual(@as(u16, 0x200), m.cpu.pc);
    try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.v[0x5]);
    try std.testing.expect(!m.keypad.isAwaiting());
}

test "FX0A phase 1 → 2: lowest-indexed held key is claimed and the stall continues" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{0xF50A}));
    m.setKey(0xA, true);
    m.setKey(0x3, true);
    m.setKey(0xC, true);

    try std.testing.expectEqual(StepResult.waiting_for_key, m.step());

    try std.testing.expect(m.keypad.isAwaiting());
    try std.testing.expectEqual(@as(u16, 0x200), m.cpu.pc);
}

test "FX0A phase 2 stall: claimed key still held — keeps stalling without advancing PC" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.cpu.v[0x5] = 0xAB;
    try m.loadRom(&assemble(.{0xF50A}));
    m.setKey(0x7, true);

    try std.testing.expectEqual(StepResult.waiting_for_key, m.step());
    try std.testing.expectEqual(StepResult.waiting_for_key, m.step());
    try std.testing.expectEqual(StepResult.waiting_for_key, m.step());

    try std.testing.expect(m.keypad.isAwaiting());
    try std.testing.expectEqual(@as(u16, 0x200), m.cpu.pc);
    try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.v[0x5]);
}

test "FX0A phase 2 consume: claimed key released writes V[X] = K, clears claim, advances PC, returns ran" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{ 0xF50A, 0xF50A }));
    m.setKey(0x7, true);

    try std.testing.expectEqual(StepResult.waiting_for_key, m.step());
    m.setKey(0x7, false);

    try std.testing.expectEqual(StepResult.ran, m.step());

    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
    try std.testing.expectEqual(@as(u8, 0x07), m.cpu.v[0x5]);
    try std.testing.expect(!m.keypad.isAwaiting());

    try std.testing.expectEqual(StepResult.waiting_for_key, m.step());
    try std.testing.expectEqual(@as(u16, 0x202), m.cpu.pc);
}

test "runUntil breaks on waiting_for_key and propagates the variant" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{0xF50A}));

    const Predicate = struct {
        fn never(_: *const Machine) bool {
            return false;
        }
    };

    try std.testing.expectEqual(StepResult.waiting_for_key, m.runUntil(Predicate.never));
    try std.testing.expectEqual(@as(u16, 0x200), m.cpu.pc);
}

test "runCycles: FX0A stall keeps incrementing timing.cycles (cycles ≠ instructions, per ADR 0013)" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{0xF50A}));

    const ran = m.runCycles(50);

    try std.testing.expectEqual(@as(u64, 50), ran);
    try std.testing.expectEqual(@as(u64, 50), m.timing.cycles);
    try std.testing.expectEqual(@as(u16, 0x200), m.cpu.pc);
}

test "FX0A discards pre-fetch keypad noise — only keys held when FX0A is reached are observed" {
    var m = Machine.init(.{});
    defer m.deinit();
    m.setKey(0x1, true);
    m.setKey(0x1, false);
    m.setKey(0xB, true);
    m.setKey(0xB, false);
    try m.loadRom(&assemble(.{0xF50A}));

    try std.testing.expectEqual(StepResult.waiting_for_key, m.step());

    try std.testing.expect(!m.keypad.isAwaiting());
    try std.testing.expectEqual(@as(u16, 0x200), m.cpu.pc);
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

test "FX55: no_index_increment=true stores V0..VX to RAM[I..] but leaves I unchanged" {
    var m = Machine.init(.{ .quirks = .{ .no_index_increment = true } });
    defer m.deinit();
    for (0..16) |j| m.cpu.v[j] = @as(u8, @intCast(j)) +% 0xA0;
    m.cpu.i = 0x300;
    try m.loadRom(&assemble(.{0xFF55}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    for (0..16) |j| {
        try std.testing.expectEqual(@as(u8, @intCast(j)) +% 0xA0, m.bus.ram[0x300 + j]);
    }
    try std.testing.expectEqual(@as(u16, 0x300), m.cpu.i);
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

test "FX65: no_index_increment=true loads V0..VX from RAM[I..] but leaves I unchanged" {
    var m = Machine.init(.{ .quirks = .{ .no_index_increment = true } });
    defer m.deinit();
    m.cpu.i = 0x300;
    for (0..16) |j| m.bus.ram[0x300 + j] = @as(u8, @intCast(j)) +% 0xA0;
    try m.loadRom(&assemble(.{0xFF65}));

    try std.testing.expectEqual(StepResult.ran, m.step());

    for (0..16) |j| {
        try std.testing.expectEqual(@as(u8, @intCast(j)) +% 0xA0, m.cpu.v[j]);
    }
    try std.testing.expectEqual(@as(u16, 0x300), m.cpu.i);
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

// Test-only sink that concatenates every write into a fixed buffer and
// counts calls. The comptime `is_test` branch makes the strip explicit:
// non-test builds resolve `BufferSink` to `void`, so any accidental use
// outside a test block becomes a compile error rather than silent dead code.
const BufferSink = if (@import("builtin").is_test) struct {
    buf: []u8,
    len: usize = 0,
    write_count: usize = 0,

    fn writeFn(ctx: *anyopaque, line: []const u8) void {
        const self: *BufferSink = @ptrCast(@alignCast(ctx));
        @memcpy(self.buf[self.len .. self.len + line.len], line);
        self.len += line.len;
        self.write_count += 1;
    }

    fn sink(self: *BufferSink) trace_mod.TraceSink {
        return .{ .write = writeFn, .ctx = self };
    }

    fn slice(self: *const BufferSink) []const u8 {
        return self.buf[0..self.len];
    }
} else void;

test "trace writer emits one line per cycle in the frozen XXXX:OOOO MNEMONIC <state-delta> format" {
    // Format frozen this PR: future state-delta tokens may extend the set
    // (BCD, ST, etc.) but never reorder. The four ROM ops here pin the
    // V[X]=, I=, PC= tokens and the V<hex> / 0xNN / 0xNNN substitutions.
    var buf: [1024]u8 = undefined;
    var sink_state: BufferSink = .{ .buf = &buf };
    var m = Machine.init(.{ .trace = sink_state.sink() });
    defer m.deinit();
    try m.loadRom(&assemble(.{ 0x6A42, 0x7A01, 0xA300, 0x1234 }));

    _ = m.runCycles(4);

    const expected =
        "0200:6A42 LD VA, 0x42 V[A]=0x42\n" ++
        "0202:7A01 ADD VA, 0x01 V[A]=0x43\n" ++
        "0204:A300 LD I, 0x300 I=0x300\n" ++
        "0206:1234 JP 0x234 PC=0x234\n";
    try std.testing.expectEqualStrings(expected, sink_state.slice());
    try std.testing.expectEqual(@as(usize, 4), sink_state.write_count);
}

test "trace writer is zero-cost when null: cpu/framebuffer/timing state byte-identical to a non-null run" {
    // Same ROM driven twice; the only configuration difference is the trace
    // sink. Byte-identical post-state proves the trace path has no observable
    // side effect on the machine — load-bearing for ADR 0006's "zero-cost
    // when unused" promise.
    const program = assemble(.{
        0x6042, 0x6101, 0x8014, 0xA300, 0xD011, 0xD011, 0x1234,
    });

    var no_trace = Machine.init(.{});
    defer no_trace.deinit();
    no_trace.bus.ram[0x300] = 0xFF;
    try no_trace.loadRom(&program);
    _ = no_trace.runCycles(7);

    var buf: [1024]u8 = undefined;
    var sink_state: BufferSink = .{ .buf = &buf };
    var with_trace = Machine.init(.{ .trace = sink_state.sink() });
    defer with_trace.deinit();
    with_trace.bus.ram[0x300] = 0xFF;
    try with_trace.loadRom(&program);
    _ = with_trace.runCycles(7);

    try std.testing.expectEqualSlices(u8, &no_trace.cpu.v, &with_trace.cpu.v);
    try std.testing.expectEqual(no_trace.cpu.i, with_trace.cpu.i);
    try std.testing.expectEqual(no_trace.cpu.pc, with_trace.cpu.pc);
    try std.testing.expectEqual(no_trace.cpu.sp, with_trace.cpu.sp);
    try std.testing.expectEqualSlices(u16, &no_trace.cpu.stack, &with_trace.cpu.stack);
    try std.testing.expectEqualSlices(u1, &no_trace.framebuffer.pixels, &with_trace.framebuffer.pixels);
    try std.testing.expectEqual(no_trace.timing.delay_timer, with_trace.timing.delay_timer);
    try std.testing.expectEqual(no_trace.timing.cycles, with_trace.timing.cycles);
}

test "sprite-draw log emits one record per DXYN with cycle, x, y, n, collision" {
    // 3-op ROM: A300 sets I to a sentinel sprite byte (0xFF, pre-written),
    // then DRW V0,V0,1 twice. First draw lights 8 pixels (col=0); second
    // erases them (col=1). cycle=1 / cycle=2 because timing.cycles is
    // bumped *after* each step in runCycles, so DXYN sees the post-bump
    // count of preceding cycles.
    var buf: [256]u8 = undefined;
    var sink_state: BufferSink = .{ .buf = &buf };
    var m = Machine.init(.{
        .sprite_log = sink_state.sink(),
        .quirks = .{ .vblank_wait_on_draw = false },
    });
    defer m.deinit();
    m.bus.ram[0x300] = 0xFF;
    try m.loadRom(&assemble(.{ 0xA300, 0xD001, 0xD001 }));

    _ = m.runCycles(3);

    const expected =
        "cycle=1 x=0 y=0 n=1 col=0\n" ++
        "cycle=2 x=0 y=0 n=1 col=1\n";
    try std.testing.expectEqualStrings(expected, sink_state.slice());
    try std.testing.expectEqual(@as(usize, 2), sink_state.write_count);
}

test "trace state-delta tokens render as locked: FB-CLEAR, V[X]=, VF=, DT=, I=, FB-XOR, (no-op)" {
    // Pins the rest of the frozen token set the tracer-bullet test doesn't
    // reach. Single ROM threads CLS → LD → ADD (VF write) → LD DT, V0 → LD I →
    // DRW → SYS so every locked state-delta token appears exactly once.
    var buf: [1024]u8 = undefined;
    var sink_state: BufferSink = .{ .buf = &buf };
    var m = Machine.init(.{
        .trace = sink_state.sink(),
        .quirks = .{ .vblank_wait_on_draw = false },
    });
    defer m.deinit();
    m.bus.ram[0x300] = 0xFF;
    m.bus.ram[0x301] = 0xFF;
    try m.loadRom(&assemble(.{
        0x00E0, 0x6005, 0x6103, 0x8014, 0xF015, 0xA300, 0xD012, 0x0123,
    }));

    _ = m.runCycles(8);

    const expected =
        "0200:00E0 CLS FB-CLEAR\n" ++
        "0202:6005 LD V0, 0x05 V[0]=0x05\n" ++
        "0204:6103 LD V1, 0x03 V[1]=0x03\n" ++
        "0206:8014 ADD V0, V1 V[0]=0x08 VF=0x00\n" ++
        "0208:F015 LD DT, V0 DT=0x08\n" ++
        "020A:A300 LD I, 0x300 I=0x300\n" ++
        "020C:D012 DRW V0, V1, 0x2 FB-XOR x=8 y=3 n=2 col=0\n" ++
        "020E:0123 SYS 0x123 (no-op)\n";
    try std.testing.expectEqualStrings(expected, sink_state.slice());
}

test "trace DXYN renders the pre-step coord even when X- or Y-reg is VF (collision-flag overwrite)" {
    // DXYN writes V[F] = collision before the trace path runs. A naive impl
    // that re-reads cpu.v[0xF] post-step would render the collision flag
    // instead of the pre-step value the draw used as the coordinate. Vanilla
    // ROMs rarely use VF as a coord, but valid CHIP-8 programs can — this
    // pins the format-frozen behavior.
    var buf: [256]u8 = undefined;
    var sink_state: BufferSink = .{ .buf = &buf };
    var m = Machine.init(.{
        .trace = sink_state.sink(),
        .quirks = .{ .vblank_wait_on_draw = false },
    });
    defer m.deinit();
    m.cpu.v[0xF] = 5;
    m.bus.ram[0x300] = 0xFF;
    try m.loadRom(&assemble(.{ 0xA300, 0xDFF1 }));

    _ = m.runCycles(2);

    const out = sink_state.slice();
    // Pre-step V[F]=5, so DRW VF, VF, 1 draws at (5, 5) with col=0. Buggy
    // post-step read would render x=0 y=0 because V[F] is now the collision flag.
    try std.testing.expect(std.mem.indexOf(u8, out, "FB-XOR x=5 y=5 n=1 col=0") != null);
}

test "trace mnemonic substitution respects word boundaries: AND, RND, SNE keep their literal Ns" {
    // The placeholder substitutor must only rewrite N/NN/NNN/VX/VY at word
    // boundaries. A naive impl that matched 'N' anywhere would clobber the
    // 'N' inside AND, RND, SNE, SUBN — those mnemonics would render with
    // bogus hex spliced into the middle of the opcode name.
    var buf: [1024]u8 = undefined;
    var sink_state: BufferSink = .{ .buf = &buf };
    var m = Machine.init(.{ .trace = sink_state.sink(), .rng_seed = 0 });
    defer m.deinit();
    m.cpu.v[0x1] = 0xAA;
    m.cpu.v[0x2] = 0x55;
    m.cpu.v[0x3] = 0x77;
    try m.loadRom(&assemble(.{ 0x8122, 0xC1FF, 0x9230 }));

    _ = m.runCycles(3);

    const out = sink_state.slice();
    try std.testing.expect(std.mem.indexOf(u8, out, "AND V1, V2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "RND V1, 0xFF") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SNE V2, V3") != null);
}

test "sprite-draw log null sink receives zero writes when DXYN executes" {
    var buf: [256]u8 = undefined;
    const sink_state: BufferSink = .{ .buf = &buf };
    var m = Machine.init(.{ .sprite_log = null });
    defer m.deinit();
    m.bus.ram[0x300] = 0xFF;
    try m.loadRom(&assemble(.{ 0xA300, 0xD001, 0xD001 }));

    _ = m.runCycles(3);

    try std.testing.expectEqual(@as(usize, 0), sink_state.write_count);
    try std.testing.expectEqual(@as(usize, 0), sink_state.len);
}

test "trace writer null sink receives zero writes" {
    var buf: [256]u8 = undefined;
    const sink_state: BufferSink = .{ .buf = &buf };
    var m = Machine.init(.{ .trace = null });
    defer m.deinit();
    try m.loadRom(&assemble(.{ 0x6A42, 0x7A01, 0xA300, 0x1234 }));

    _ = m.runCycles(4);

    // Sentinel: the sink was never wired in, so the buffer is untouched.
    try std.testing.expectEqual(@as(usize, 0), sink_state.write_count);
    try std.testing.expectEqual(@as(usize, 0), sink_state.len);
}
