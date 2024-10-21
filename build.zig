const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "units",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const quickjs = b.dependency("quickjs", .{});

    exe.addCSourceFiles(.{
        .root = quickjs.path(""),
        .files = &.{
            "cutils.c",
            "libbf.c",
            "libregexp.c",
            "libunicode.c",
            "quickjs.c",
        },
        .flags = if (optimize == .Debug)
            // have UBSan print a description of the error instead of inserting an illegal instruction
            &.{
                "-fno-sanitize-trap=undefined",
                "-fno-sanitize-recover=undefined",
                // quickjs does pointer arithmetic on null
                "-fno-sanitize=pointer-overflow",
            }
        else
            &.{},
    });
    exe.linkLibC();
    if (optimize == .Debug) {
        exe.linkSystemLibrary("ubsan");
    }

    const quickjs_header = b.addTranslateC(.{
        .root_source_file = quickjs.path("quickjs.h"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("quickjs.h", quickjs_header.createModule());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    if (optimize == .Debug) {
        run_cmd.setEnvironmentVariable("UBSAN_OPTIONS", "print_stacktrace=1");
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
