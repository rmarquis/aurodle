const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version is derived from git at build time as `r<count>.<hash>`, where
    // `<count>` is the commit count and `<hash>` the abbreviated commit hash.
    // There is no version literal in src/.
    //
    // A config-time `b.run` is only re-evaluated when a build-graph input
    // changes, and `.git` is not one. Building after a commit that touched no
    // compile input — docs, empty commits, or a `git pull` of such history —
    // stamped the *previous* commit into `--version`; editing a source file
    // happened to mask it. This `Run` step re-runs git every build instead
    // (~10 ms), and downstream steps stay cached when the emitted text is
    // unchanged.
    const version_gen = b.addSystemCommand(&.{
        "sh", "-c",
        \\v="$(printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)")"
        \\printf 'pub const version = "%s";\n' "$v" > "$1"
        ,
        "aurodle-version", // $0; $1 becomes the generated file path
    });
    version_gen.has_side_effects = true;
    const version_file = version_gen.addOutputFileArg("version.zig");
    const version_mod = b.createModule(.{
        .root_source_file = version_file,
        .target = target,
    });

    const mod = b.addModule("aurodle", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    mod.linkSystemLibrary("alpm", .{});

    const alpm_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/alpm_c.h"),
        .target = target,
        .optimize = optimize,
    });
    alpm_translate_c.linkSystemLibrary("alpm", .{});
    const alpm_c_module = alpm_translate_c.createModule();
    mod.addImport("alpm_c", alpm_c_module);

    const exe = b.addExecutable(.{
        .name = "aurodle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aurodle", .module = mod },
                .{ .name = "build_options", .module = version_mod },
                .{ .name = "alpm_c", .module = alpm_c_module },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

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
