const std = @import("std");
const builtin = @import("builtin");

const required_zig_version = "0.16.0";

pub fn build(b: *std.Build) void {
    comptime {
        if (!std.mem.eql(u8, builtin.zig_version_string, required_zig_version)) {
            @compileError("weft requires Zig " ++ required_zig_version ++ "; found " ++ builtin.zig_version_string);
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only tests whose name contains one of these substrings",
    ) orelse &.{};

    const netz_dep = b.dependency("netz", .{
        .target = target,
        .optimize = optimize,
    });
    const netz_mod = netz_dep.module("netz");

    const weft_mod = b.addModule("weft", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "netz", .module = netz_mod },
        },
    });

    const lib = b.addLibrary(.{
        .name = "weft",
        .root_module = weft_mod,
    });
    b.installArtifact(lib);

    const lib_tests = b.addTest(.{
        .root_module = weft_mod,
        .filters = test_filters,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Compile and run weft unit tests");
    test_step.dependOn(&run_lib_tests.step);

    const package_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/package_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "weft", .module = weft_mod }},
        }),
        .filters = test_filters,
    });
    const run_package_tests = b.addRunArtifact(package_tests);
    const test_package_step = b.step(
        "test-package",
        "Compile and run the public weft package tests",
    );
    test_package_step.dependOn(&run_package_tests.step);
    test_step.dependOn(&run_package_tests.step);

    const example = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
                .{ .name = "netz", .module = netz_mod },
            },
        }),
    });
    b.installArtifact(example);
    const run_example = b.addRunArtifact(example);
    const run_hello_step = b.step("run-hello", "Run the hello example");
    run_hello_step.dependOn(&run_example.step);

    const examples_step = b.step("examples", "Build all examples");
    examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);
}
