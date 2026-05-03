//! Tier 1 debug affordance: per-cycle trace logging and per-draw sprite log
//! (ADR 0006). The `TraceSink` shape lets the frontend own file/buffer state
//! without `chippy_core` gaining file-IO knowledge. Both formatters write into
//! a caller-supplied fixed buffer — no allocation in core (CLAUDE.md rule 12).
//!
//! Line format is **frozen** at M2.10: future state-delta tokens may extend
//! the set (e.g. ST=0xNN once FX18 lands at M5, BCD=H,T,U for FX33) but never
//! reorder. Tokens emitted today: `V[X]=0xNN`, `I=0xNNN`, `PC=0xNNN`,
//! `DT=0xNN`, `VF=0xNN`, `FB-CLEAR`, `FB-XOR x=N y=N n=N col=C`, `(no-op)`.

const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const disasm_mod = @import("disasm.zig");
const decode = @import("decode.zig");

pub const TraceSink = struct {
    write: *const fn (ctx: *anyopaque, line: []const u8) void,
    ctx: *anyopaque,
};

pub const Snapshot = struct {
    cpu: *const Cpu,
    delay_timer: u8,
};

/// `<pre_pc>:<opcode> <mnemonic-with-substitutions> <state-delta>\n`. The
/// caller supplies the buffer — 128 bytes is enough for any line the M2.10
/// opcode set produces, with headroom for future extensions.
pub fn formatTraceLine(buf: []u8, pre_pc: u16, opcode: u16, snap: Snapshot) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try w.print("{X:0>4}:{X:0>4} ", .{ pre_pc, opcode });
    try writeMnemonic(&w, opcode);
    try w.writeByte(' ');
    try writeStateDelta(&w, opcode, snap);
    try w.writeByte('\n');
    return w.buffered();
}

/// `cycle=N x=N y=N n=N col=C\n`. Decimal so logs are diff-friendly when a
/// regression test compares two runs.
pub fn formatSpriteLog(buf: []u8, cycle: u64, x: u8, y: u8, n: u4, collision: bool) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try w.print("cycle={d} x={d} y={d} n={d} col={d}\n", .{
        cycle, x, y, n, @intFromBool(collision),
    });
    return w.buffered();
}

/// Substitutes `VX`/`VY`/`NNN`/`NN`/`N` placeholders in the disasm mnemonic
/// with their decoded values, but only at word boundaries — otherwise the
/// `N` inside mnemonics like `AND`, `RND`, `SNE`, `SUBN` would get clobbered.
fn writeMnemonic(w: *std.Io.Writer, opcode: u16) !void {
    const entry = disasm_mod.disasm(opcode);
    const s = entry.mnemonic;
    var i: usize = 0;
    while (i < s.len) {
        if (atBoundary(s, i)) {
            if (matchToken(s, i, "NNN")) {
                try w.print("0x{X:0>3}", .{entry.nnn});
                i += 3;
                continue;
            }
            if (matchToken(s, i, "NN")) {
                try w.print("0x{X:0>2}", .{entry.nn});
                i += 2;
                continue;
            }
            if (matchToken(s, i, "VX")) {
                try w.print("V{X}", .{entry.x});
                i += 2;
                continue;
            }
            if (matchToken(s, i, "VY")) {
                try w.print("V{X}", .{entry.y});
                i += 2;
                continue;
            }
            if (matchToken(s, i, "N")) {
                try w.print("0x{X}", .{entry.n});
                i += 1;
                continue;
            }
        }
        try w.writeByte(s[i]);
        i += 1;
    }
}

fn atBoundary(s: []const u8, i: usize) bool {
    return i == 0 or s[i - 1] == ' ' or s[i - 1] == ',';
}

fn matchToken(s: []const u8, i: usize, token: []const u8) bool {
    if (i + token.len > s.len) return false;
    if (!std.mem.eql(u8, s[i .. i + token.len], token)) return false;
    const after = i + token.len;
    return after == s.len or s[after] == ' ' or s[after] == ',';
}

fn writeStateDelta(w: *std.Io.Writer, opcode: u16, snap: Snapshot) !void {
    const cpu = snap.cpu;
    switch (opcode & 0xF000) {
        0x0000 => switch (opcode) {
            0x00E0 => try w.writeAll("FB-CLEAR"),
            0x00EE => try w.print("PC=0x{X:0>3}", .{cpu.pc}),
            else => try w.writeAll("(no-op)"),
        },
        0x1000, 0x2000, 0x3000, 0x4000, 0x5000, 0x9000, 0xB000 => try w.print("PC=0x{X:0>3}", .{cpu.pc}),
        0x6000, 0x7000, 0xC000 => {
            const x = decode.opX(opcode);
            try w.print("V[{X}]=0x{X:0>2}", .{ x, cpu.v[x] });
        },
        0x8000 => {
            const x = decode.opX(opcode);
            switch (decode.opN(opcode)) {
                0x0 => try w.print("V[{X}]=0x{X:0>2}", .{ x, cpu.v[x] }),
                0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0xE => try w.print(
                    "V[{X}]=0x{X:0>2} VF=0x{X:0>2}",
                    .{ x, cpu.v[x], cpu.v[0xF] },
                ),
                else => try w.writeAll("(no-op)"),
            }
        },
        0xA000 => try w.print("I=0x{X:0>3}", .{cpu.i}),
        0xD000 => {
            // Vx and Vy are not modified by DXYN, so post-step cpu.v[x] is the
            // pre-step value the draw actually used. VF holds the collision flag.
            const x_reg = decode.opX(opcode);
            const y_reg = decode.opY(opcode);
            try w.print("FB-XOR x={d} y={d} n={d} col={d}", .{
                cpu.v[x_reg], cpu.v[y_reg], decode.opN(opcode), cpu.v[0xF],
            });
        },
        0xF000 => switch (decode.opNN(opcode)) {
            0x07 => {
                const x = decode.opX(opcode);
                try w.print("V[{X}]=0x{X:0>2}", .{ x, cpu.v[x] });
            },
            0x15 => try w.print("DT=0x{X:0>2}", .{snap.delay_timer}),
            0x1E, 0x29, 0x33, 0x55, 0x65 => try w.print("I=0x{X:0>3}", .{cpu.i}),
            else => try w.writeAll("(no-op)"),
        },
        else => try w.writeAll("(no-op)"),
    }
}
