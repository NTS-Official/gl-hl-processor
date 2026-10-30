const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.option(bool, "shared", "Build glsl2hlsl as a shared library") orelse false;
    const with_cli = b.option(bool, "cli", "Build the glsl2hlsl command line tool") orelse false;

    const mod = b.addModule("processor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const lib = b.addLibrary(.{
        .name = "glsl2hlsl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = if (shared) .dynamic else .static,
    });
    b.installArtifact(lib);
    b.installFile("include/glsl2hlsl/glsl2hlsl.h", "include/glsl2hlsl/glsl2hlsl.h");
    b.installFile("include/glsl2hlsl/glsl2hlsl.hpp", "include/glsl2hlsl/glsl2hlsl.hpp");

    const test_step = b.step("test", "Run unit tests");
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    if (with_cli) {
        const exe = b.addExecutable(.{
            .name = "glsl2hlsl",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "processor", .module = mod },
                },
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        const run_step = b.step("run", "Run the converter");
        run_step.dependOn(&run_cmd.step);

        const exe_tests = b.addTest(.{
            .root_module = exe.root_module,
        });
        test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    }

    const cpp_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    cpp_mod.addCSourceFile(.{
        .file = b.path("tests/cpp/interop_test.cpp"),
        .flags = &.{"-std=c++17"},
    });
    cpp_mod.addIncludePath(b.path("include"));

    const cpp_test = b.addExecutable(.{
        .name = "glsl2hlsl_cpp_test",
        .root_module = cpp_mod,
    });
    cpp_test.root_module.linkLibrary(lib);

    const cpp_step = b.step("cpp-test", "Build and run the C++ interoperability test");
    cpp_step.dependOn(&b.addRunArtifact(cpp_test).step);
}
