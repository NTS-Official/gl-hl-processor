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

    const c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_mod.addCSourceFile(.{
        .file = b.path("tests/c/interop_test.c"),
        .flags = &.{ "-std=c23", "-Wall", "-Wextra", "-Werror" },
    });
    c_mod.addIncludePath(b.path("include"));

    const c_test = b.addExecutable(.{
        .name = "glsl2hlsl_c_test",
        .root_module = c_mod,
    });
    c_test.root_module.linkLibrary(lib);

    const c_step = b.step("c-test", "Build and run the C interoperability test");
    c_step.dependOn(&b.addRunArtifact(c_test).step);

    const cpp23_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    cpp23_mod.addCSourceFile(.{
        .file = b.path("tests/cpp/interop_test.cpp"),
        .flags = &.{ "-std=c++23", "-Wall", "-Wextra", "-Werror" },
    });
    cpp23_mod.addIncludePath(b.path("include"));

    const cpp23_test = b.addExecutable(.{
        .name = "glsl2hlsl_cpp23_test",
        .root_module = cpp23_mod,
    });
    cpp23_test.root_module.linkLibrary(lib);

    const cpp26_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    cpp26_mod.addCSourceFile(.{
        .file = b.path("tests/cpp/interop_test.cpp"),
        .flags = &.{ "-std=c++26", "-Wall", "-Wextra", "-Werror" },
    });
    cpp26_mod.addIncludePath(b.path("include"));

    const cpp26_test = b.addExecutable(.{
        .name = "glsl2hlsl_cpp26_test",
        .root_module = cpp26_mod,
    });
    cpp26_test.root_module.linkLibrary(lib);

    const cpp_step = b.step("cpp-test", "Build and run the C++ interoperability tests");
    cpp_step.dependOn(&b.addRunArtifact(cpp23_test).step);
    cpp_step.dependOn(&b.addRunArtifact(cpp26_test).step);
}
