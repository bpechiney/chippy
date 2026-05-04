//! Multi-window pre-flight trace for `tests/test_roms/beep.ch8` (M5.3, issue #103).
//!
//! Encodes the M3 retro `verify/`-pattern bullet plus the M4.2 multi-window
//! refinement (`docs/next-target-handoff.md`): boot / mid-test / post-test /
//! idle windows, with per-window opcode-set + FX18 calls + audio bool-stream
//! transitions and plateau lengths. PRD validation needs a trace, not a prose
//! reading — the PR description for #103 cites this file's path and quotes
//! findings.
//!
//! Build invocation locked into `verify/README.md`. The verify module is
//! kept outside `tests/integration/` because the integration-test module
//! imports `chippy_core` only via its public API (ADR 0014); this scratch
//! program reaches CPU/Bus/Timing fields directly via `Machine.*` which is
//! the public root-exported type, but does so for diagnostics, not for the
//! product surface.

const std = @import("std");
const chippy = @import("chippy_core");
const Machine = chippy.Machine;
const Options = chippy.Options;
const AudioSink = chippy.AudioSink;

const ROM_PATH = "tests/test_roms/beep.ch8";

// 600 frames covers two full SOS cycles (period ~280 frames at vanilla VIP
// 700 Hz / 60 Hz) plus headroom for the boot phase and any post-cycle
// re-entry, satisfying the M4.2 boot/mid/post/idle multi-window requirement.
const TOTAL_FRAMES: u32 = 600;

const OpcodeCount = struct {
    opcode: u16,
    count: u32,
};

const Fx18Event = struct {
    frame: u32,
    cycle: u64,
    vx_index: u4,
    vx_value: u8,
};

const Window = struct {
    label: []const u8,
    start_frame: u32,
    end_frame: u32, // inclusive
};

const Recorder = struct {
    audio: [TOTAL_FRAMES]bool = [_]bool{false} ** TOTAL_FRAMES,
    audio_count: u32 = 0,
    op_counts_per_window: [4]std.AutoHashMap(u16, u32),
    fx18_per_window: [4]std.ArrayList(Fx18Event),
    blocking_per_window: [4]u32 = [_]u32{0} ** 4,

    fn audioWrite(ctx: *anyopaque, beeping: bool) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.audio_count >= self.audio.len) return;
        self.audio[self.audio_count] = beeping;
        self.audio_count += 1;
    }
};

fn windowIndexFor(windows: []const Window, frame: u32) ?usize {
    for (windows, 0..) |w, idx| {
        if (frame >= w.start_frame and frame <= w.end_frame) return idx;
    }
    return null;
}

// Plateau search over the audio bool stream: emits a list of (value, run_len)
// segments. Same shape as M4.4's framebuffer plateau search but applied to
// the bool stream. Used to anchor the keystone N — the centre of the longest
// stable plateau is the most robust checkpoint.
const Plateau = struct {
    value: bool,
    start_frame: u32,
    length: u32,
};

fn plateaus(stream: []const bool, alloc: std.mem.Allocator) !std.ArrayList(Plateau) {
    var out: std.ArrayList(Plateau) = .empty;
    if (stream.len == 0) return out;
    var current = stream[0];
    var run_start: u32 = 0;
    var i: u32 = 1;
    while (i < stream.len) : (i += 1) {
        if (stream[i] != current) {
            try out.append(alloc, .{ .value = current, .start_frame = run_start, .length = i - run_start });
            current = stream[i];
            run_start = i;
        }
    }
    try out.append(alloc, .{ .value = current, .start_frame = run_start, .length = @as(u32, @intCast(stream.len)) - run_start });
    return out;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const cwd = std.Io.Dir.cwd();
    const rom = try cwd.readFileAlloc(io, ROM_PATH, allocator, .limited(chippy.ROM_MAX_BYTES));
    defer allocator.free(rom);

    // Window placement is fixed up front from the SOS-pattern math (each
    // beep cycle ~280 frames @ vanilla VIP timing): boot covers the first
    // FX18 firing plus initial silence, mid-test sits inside the dash run
    // (longest beeps), post-test is the long-tail off period at end of one
    // SOS cycle, idle is the start of the second SOS cycle so we observe
    // re-entry. Real plateau-pinned N is chosen *from* the trace below, not
    // here — windows are diagnostic only.
    const windows = [_]Window{
        .{ .label = "boot", .start_frame = 0, .end_frame = 49 },
        .{ .label = "mid-test", .start_frame = 50, .end_frame = 199 },
        .{ .label = "post-test", .start_frame = 200, .end_frame = 349 },
        .{ .label = "idle", .start_frame = 350, .end_frame = TOTAL_FRAMES - 1 },
    };

    var rec: Recorder = .{
        .op_counts_per_window = [_]std.AutoHashMap(u16, u32){
            std.AutoHashMap(u16, u32).init(allocator),
            std.AutoHashMap(u16, u32).init(allocator),
            std.AutoHashMap(u16, u32).init(allocator),
            std.AutoHashMap(u16, u32).init(allocator),
        },
        .fx18_per_window = [_]std.ArrayList(Fx18Event){ .empty, .empty, .empty, .empty },
    };

    const sink: AudioSink = .{ .write = Recorder.audioWrite, .ctx = &rec };
    var m = Machine.init(.{ .audio_sink = sink });
    defer m.deinit();
    try m.loadRom(rom);

    // Per-cycle drive: pre-fetch opcode + V-state, count, then `runCycles(1)`
    // (per the M4.4 lesson — drivers route through Machine.runCycles(1) so
    // they inherit the cycle/halt contract). After the frame-boundary's
    // worth of cycles, call `runFrame`'s tail (tickTimers + emitAudio) so
    // the audio sink fires; we drive `runFrame` directly for that.
    var frame: u32 = 0;
    while (frame < TOTAL_FRAMES) : (frame += 1) {
        const widx = windowIndexFor(&windows, frame) orelse {
            m.runFrame();
            continue;
        };

        const cycles_per_frame = (Options{}).cycles_per_second / 60;
        var c: u32 = 0;
        while (c < cycles_per_frame) : (c += 1) {
            const pre_pc = m.cpu.pc;
            const opcode = m.bus.read16(pre_pc);

            const gop = try rec.op_counts_per_window[widx].getOrPut(opcode);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;

            // FX18 capture: V[X] is read at pre-step time so the recorded
            // value is the one the opcode is about to write into ST.
            if ((opcode & 0xF0FF) == 0xF018) {
                const x: u4 = @intCast((opcode & 0x0F00) >> 8);
                try rec.fx18_per_window[widx].append(allocator, .{
                    .frame = frame,
                    .cycle = m.timing.cycles,
                    .vx_index = x,
                    .vx_value = m.cpu.v[x],
                });
            }

            const before_cycles = m.timing.cycles;
            _ = m.runCycles(1);
            const after_cycles = m.timing.cycles;
            // PC didn't move + no cycle progress would mean halted; runCycles
            // increments timing.cycles even on a vblank-wait stall, so a
            // stall frame still bumps cycles. We classify "blocking" as
            // "PC unchanged after one cycle" — covers DXYN's vblank-wait.
            if (m.cpu.pc == pre_pc and after_cycles == before_cycles + 1) {
                rec.blocking_per_window[widx] += 1;
            }
        }
        m.tickTimers();
        // `Machine.emitAudio` is private, so mirror it by calling the sink
        // directly with the post-tick beeping bit — same shape as `runFrame`'s
        // tail per ADR 0015.
        try sink.write(sink.ctx, m.timing.sound_timer > 0);
    }

    try stdout.print("# verify_beep — multi-window pre-flight trace\n\n", .{});
    try stdout.print("ROM: {s}\n", .{ROM_PATH});
    try stdout.print("Total frames simulated: {d}\n", .{TOTAL_FRAMES});
    try stdout.print("Audio bool stream length: {d}\n\n", .{rec.audio_count});

    for (windows, 0..) |w, idx| {
        try stdout.print("## Window {d}: {s} (frames {d}–{d}, {d} frames)\n\n", .{
            idx, w.label, w.start_frame, w.end_frame, w.end_frame - w.start_frame + 1,
        });

        try stdout.print("### Opcodes hit\n", .{});
        var op_iter = rec.op_counts_per_window[idx].iterator();
        var op_list: std.ArrayList(OpcodeCount) = .empty;
        defer op_list.deinit(allocator);
        while (op_iter.next()) |entry| {
            try op_list.append(allocator, .{ .opcode = entry.key_ptr.*, .count = entry.value_ptr.* });
        }
        std.mem.sort(OpcodeCount, op_list.items, {}, struct {
            fn lt(_: void, a: OpcodeCount, b: OpcodeCount) bool {
                return a.opcode < b.opcode;
            }
        }.lt);
        for (op_list.items) |oc| {
            try stdout.print("  {X:0>4}  ×{d}\n", .{ oc.opcode, oc.count });
        }
        try stdout.print("\nBlocking-stall cycles (PC-unchanged steps, e.g. DXYN vBlank-wait): {d}\n\n", .{rec.blocking_per_window[idx]});

        try stdout.print("### FX18 calls (set sound timer)\n", .{});
        if (rec.fx18_per_window[idx].items.len == 0) {
            try stdout.print("  (none)\n", .{});
        } else {
            for (rec.fx18_per_window[idx].items) |ev| {
                try stdout.print("  frame={d} cycle={d}  V[{X}]=0x{X:0>2} ({d})\n", .{
                    ev.frame, ev.cycle, ev.vx_index, ev.vx_value, ev.vx_value,
                });
            }
        }
        try stdout.print("\n", .{});

        // Audio plateaus inside the window
        const ws = w.start_frame;
        const we = @min(w.end_frame + 1, rec.audio_count);
        if (ws < we) {
            const slice = rec.audio[ws..we];
            var p = try plateaus(slice, allocator);
            defer p.deinit(allocator);
            try stdout.print("### Audio bool-stream plateaus\n", .{});
            for (p.items) |pl| {
                try stdout.print("  frame {d}–{d} ({d} frames): {s}\n", .{
                    ws + pl.start_frame,
                    ws + pl.start_frame + pl.length - 1,
                    pl.length,
                    if (pl.value) "BEEP" else "silent",
                });
            }
            try stdout.print("\n", .{});
        }
    }

    try stdout.print("# Plateau search across full stream (for keystone N selection)\n\n", .{});
    var full = try plateaus(rec.audio[0..rec.audio_count], allocator);
    defer full.deinit(allocator);
    var longest_silent: ?Plateau = null;
    var longest_beep: ?Plateau = null;
    for (full.items) |pl| {
        if (pl.value) {
            if (longest_beep == null or pl.length > longest_beep.?.length) longest_beep = pl;
        } else {
            if (longest_silent == null or pl.length > longest_silent.?.length) longest_silent = pl;
        }
    }
    if (longest_beep) |pl| {
        try stdout.print("Longest BEEP plateau: frames {d}–{d} ({d} frames); centre = {d}\n", .{
            pl.start_frame,                 pl.start_frame + pl.length - 1, pl.length,
            pl.start_frame + pl.length / 2,
        });
    }
    if (longest_silent) |pl| {
        try stdout.print("Longest silent plateau: frames {d}–{d} ({d} frames); centre = {d}\n", .{
            pl.start_frame,                 pl.start_frame + pl.length - 1, pl.length,
            pl.start_frame + pl.length / 2,
        });
    }
    try stdout.print("\nFull plateau sequence ({d} segments):\n", .{full.items.len});
    for (full.items, 0..) |pl, i| {
        try stdout.print("  [{d}] frame {d}–{d} ({d}f): {s}\n", .{
            i,
            pl.start_frame,
            pl.start_frame + pl.length - 1,
            pl.length,
            if (pl.value) "BEEP" else "silent",
        });
    }

    // Re-run a fresh Machine to dump the framebuffer at the chosen keystone N
    // (centre of the longest silent plateau, per the M4.4 plateau-pinning lesson).
    const keystone_n: u32 = if (longest_silent) |pl| pl.start_frame + pl.length / 2 else 0;
    var m2 = Machine.init(.{});
    defer m2.deinit();
    try m2.loadRom(rom);
    var f2: u32 = 0;
    while (f2 < keystone_n) : (f2 += 1) m2.runFrame();
    var nonzero: u32 = 0;
    for (0..32) |y| {
        for (0..64) |x| {
            if (m2.framebuffer.get(@intCast(x), @intCast(y)) != 0) nonzero += 1;
        }
    }
    try stdout.print("\n# Framebuffer at keystone N = {d} (centre of longest silent plateau)\n", .{keystone_n});
    try stdout.print("non-zero pixels: {d} (out of 2048)\n", .{nonzero});

    try stdout.flush();
}
