//! Shared runner for the framebuffer-snapshot golden tests: load a ROM,
//! step the machine, then either compare the packed framebuffer against
//! the on-disk golden or rewrite it when `UPDATE_GOLDENS=1` is set.
//!
//! Files load via runtime relative paths (`cwd.readFileAlloc` with CWD =
//! repo root) instead of `@embedFile` because Zig restricts `@embedFile`
//! to paths inside the module's package directory, and `tests/test_roms/`
//! (ADR 0004) sits outside the integration-test module's root.

const std = @import("std");
const chippy = @import("chippy_core");
const Machine = chippy.Machine;
const Framebuffer = chippy.Framebuffer;
const AudioSink = chippy.AudioSink;
const assemble = chippy.assemble;

pub const PACKED_BYTES: usize = Framebuffer.PIXELS / 8;

pub const RunMode = union(enum) {
    cycles: u32,
    frames: u32,
};

/// Caller-buffer audio bool-stream recorder. The buffer must be sized for at
/// least one bool per `runFrame` call (see ADR 0015's frame-aligned cadence);
/// overflow returns `error.AudioBufferOverflow` rather than silently dropping
/// so a too-small buffer fails the test loudly. Tracks `count` separately
/// from `buf.len` so the caller can size generously and slice the captured
/// prefix on assertion.
pub const AudioRecording = struct {
    buf: []bool,
    count: usize = 0,

    fn writeFn(ctx: *anyopaque, beeping: bool) anyerror!void {
        const self: *AudioRecording = @ptrCast(@alignCast(ctx));
        if (self.count >= self.buf.len) return error.AudioBufferOverflow;
        self.buf[self.count] = beeping;
        self.count += 1;
    }

    pub fn sink(self: *AudioRecording) AudioSink {
        return .{ .write = writeFn, .ctx = self };
    }

    pub fn slice(self: *const AudioRecording) []const bool {
        return self.buf[0..self.count];
    }
};

pub const RunOptions = struct {
    rom_path: []const u8,
    golden_path: []const u8,
    run: RunMode,
    pre_run: ?*const fn (*Machine) void = null,
    audio_recording: ?*AudioRecording = null,
    /// Optional audio bool-stream golden path. When set together with
    /// `audio_recording`, the captured stream is byte-encoded (0x00/0x01
    /// per frame) and either written (UPDATE_GOLDENS) or asserted via
    /// `expectEqualSlices`. Failure messages localize to the audio path
    /// vs the framebuffer path so a diverging golden is unambiguous.
    audio_golden_path: ?[]const u8 = null,
};

pub fn runAndCompare(opts: RunOptions) !void {
    const cwd = std.Io.Dir.cwd();
    const io = std.testing.io;

    const rom = try cwd.readFileAlloc(io, opts.rom_path, std.testing.allocator, .limited(chippy.ROM_MAX_BYTES));
    defer std.testing.allocator.free(rom);

    var m = Machine.init(.{
        .audio_sink = if (opts.audio_recording) |rec| rec.sink() else null,
    });
    defer m.deinit();
    try m.loadRom(rom);

    if (opts.pre_run) |hook| hook(&m);

    switch (opts.run) {
        .cycles => |n| _ = m.runCycles(n),
        .frames => |n| {
            var i: u32 = 0;
            while (i < n) : (i += 1) m.runFrame();
        },
    }

    const actual = packFramebuffer(&m.framebuffer);

    if (updateGoldensRequested()) {
        try cwd.writeFile(io, .{ .sub_path = opts.golden_path, .data = &actual });
        if (opts.audio_golden_path) |audio_path| {
            const rec = opts.audio_recording orelse return error.AudioGoldenWithoutRecording;
            const bytes = try encodeAudioBytes(rec.slice(), std.testing.allocator);
            defer std.testing.allocator.free(bytes);
            try cwd.writeFile(io, .{ .sub_path = audio_path, .data = bytes });
        }
        return;
    }

    try compareGoldenOrLabel(opts.rom_path, opts.golden_path, &actual, "framebuffer");

    if (opts.audio_golden_path) |audio_path| {
        const rec = opts.audio_recording orelse return error.AudioGoldenWithoutRecording;
        const bytes = try encodeAudioBytes(rec.slice(), std.testing.allocator);
        defer std.testing.allocator.free(bytes);
        try compareGoldenOrLabel(opts.rom_path, audio_path, bytes, "audio bool-stream");
    }
}

fn compareGoldenOrLabel(rom_path: []const u8, golden_path: []const u8, actual: []const u8, label: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const io = std.testing.io;
    const golden = try cwd.readFileAlloc(io, golden_path, std.testing.allocator, .limited(actual.len + 1));
    defer std.testing.allocator.free(golden);
    std.testing.expectEqualSlices(u8, golden, actual) catch |err| {
        std.debug.print("\n[golden_harness] {s} mismatch: rom={s} golden={s}\n", .{ label, rom_path, golden_path });
        return err;
    };
}

fn encodeAudioBytes(stream: []const bool, alloc: std.mem.Allocator) ![]u8 {
    const out = try alloc.alloc(u8, stream.len);
    for (stream, 0..) |b, i| out[i] = if (b) 0x01 else 0x00;
    return out;
}

// Row-major, MSB = leftmost so a hex dump of the snapshot reads like the screen.
pub fn packFramebuffer(fb: *const Framebuffer) [PACKED_BYTES]u8 {
    var out: [PACKED_BYTES]u8 = [_]u8{0} ** PACKED_BYTES;
    for (0..Framebuffer.HEIGHT) |row| {
        for (0..Framebuffer.WIDTH / 8) |byte_col| {
            var b: u8 = 0;
            for (0..8) |bit| {
                const px = fb.get(byte_col * 8 + bit, row);
                b |= @as(u8, px) << @intCast(7 - bit);
            }
            out[row * (Framebuffer.WIDTH / 8) + byte_col] = b;
        }
    }
    return out;
}

pub fn updateGoldensRequested() bool {
    const v = std.testing.environ.getPosix("UPDATE_GOLDENS") orelse return false;
    return std.mem.eql(u8, v, "1");
}

test "AudioRecording.sink() captures the post-tick bool stream of a known-cycles synthetic run" {
    // Synthetic ROM: LD V0, 3 ; LD ST, V0 ; JP self. ST=3 is set during
    // frame 1; ticks decrement 3→2→1→0 over frames 1–3, so the post-tick
    // samples are [true, true, false, false, false, false] across 6 frames.
    var buf: [8]bool = undefined;
    var rec: AudioRecording = .{ .buf = &buf };
    var m = Machine.init(.{ .audio_sink = rec.sink() });
    defer m.deinit();
    try m.loadRom(&assemble(.{ 0x6003, 0xF018, 0x1204 }));

    var i: u32 = 0;
    while (i < 6) : (i += 1) m.runFrame();

    const expected = [_]bool{ true, true, false, false, false, false };
    try std.testing.expectEqualSlices(bool, &expected, rec.slice());
    try std.testing.expectEqual(@as(usize, 6), rec.count);
}

test "AudioRecording overflow surfaces as error.AudioBufferOverflow when the buffer is too small" {
    // The recording fn-pointer returns `anyerror!void`; runFrame's call site
    // intentionally swallows the error (audio is non-essential to ROM
    // correctness). The recording itself still surfaces the overflow on the
    // next frame so a too-small buffer fails its test loudly rather than
    // silently truncating the captured stream.
    var buf: [2]bool = undefined;
    var rec: AudioRecording = .{ .buf = &buf };
    var m = Machine.init(.{ .audio_sink = rec.sink() });
    defer m.deinit();
    try m.loadRom(&assemble(.{0x1200})); // JP self, silent.

    m.runFrame();
    m.runFrame();
    m.runFrame(); // 3rd write: rec.count == buf.len, write returns overflow,
    // runFrame's `catch {}` swallows it. count stays at 2.

    try std.testing.expectEqual(@as(usize, 2), rec.count);
}
