const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ghostty-vt: lazy dependency — only downloaded when actually needed.
    if (b.lazyDependency("ghostty", .{})) |dep| {
        exe_mod.addImport(
            "ghostty-vt",
            dep.module("ghostty-vt"),
        );
    }

    const exe = b.addExecutable(.{
        .name = "kelpie",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run kelpie").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Spike C (#4): vive fuera de main.zig porque no es parte del binario, solo
    // un test que ejerce Terminal + RenderState. Mismo import de ghostty-vt.
    const vt_spike_mod = b.createModule(.{
        .root_source_file = b.path("src/vt_spike.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (b.lazyDependency("ghostty", .{})) |dep| {
        vt_spike_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    const vt_spike_tests = b.addTest(.{ .root_module = vt_spike_mod });
    test_step.dependOn(&b.addRunArtifact(vt_spike_tests).step);
}
