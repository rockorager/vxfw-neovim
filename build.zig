const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const neovim_mod = b.addModule("neovim", .{
        .root_source_file = b.path("src/neovim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    neovim_mod.addImport("vaxis", vaxis_dep.module("vaxis"));

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/neovim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    {
        const example = b.addExecutable(.{
            .name = "vxfw-neovim",
            .root_source_file = b.path("example.zig"),
            .target = target,
            .optimize = optimize,
        });
        example.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
        example.root_module.addImport("neovim", neovim_mod);

        const example_step = b.step("run", "Run example");
        const example_run = b.addRunArtifact(example);
        example_step.dependOn(&example_run.step);
    }
}
