const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("aurodle", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    mod.linkSystemLibrary("alpm", .{});

    const exe = b.addExecutable(.{
        .name = "aurodle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aurodle", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Specification tests (docs/specifications/)
    const spec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("docs/specifications/aurodle/spec_root.zig"),
            .target = target,
            .link_libc = true,
            .imports = &.{
                .{ .name = "aurodle", .module = mod },
            },
        }),
    });
    spec_tests.root_module.linkSystemLibrary("alpm", .{});

    const run_spec_tests = b.addRunArtifact(spec_tests);

    const spec_step = b.step("spec", "Run specification tests");
    spec_step.dependOn(&run_spec_tests.step);
}
