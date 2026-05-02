const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // chippy_core: pure Zig module, no host deps. Tests link only this.
    const core_mod = b.addModule("chippy_core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // chippy: thin frontend executable that imports chippy_core.
    // raylib is *not* linked here yet; it lands at M6.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/frontend/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("chippy_core", core_mod);

    const exe = b.addExecutable(.{
        .name = "chippy",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the chippy frontend");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);

    const frontend_tests = b.addTest(.{ .root_module = exe_mod });
    const run_frontend_tests = b.addRunArtifact(frontend_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_frontend_tests.step);
}
