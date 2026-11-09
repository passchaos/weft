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

    const scheduling = b.option(
        []const u8,
        "scheduling",
        "zio scheduling discipline: single_executor, pinned, or work_stealing",
    );
    const netz_dep = b.dependency("netz", .{
        .target = target,
        .optimize = optimize,
        .scheduling = scheduling orelse "work_stealing",
    });
    const netz_mod = netz_dep.module("netz");
    const vort_dep = b.dependency("vort", .{
        .target = target,
        .optimize = optimize,
    });
    const vort_mod = vort_dep.module("vort");

    const weft_mod = b.addModule("weft", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "netz", .module = netz_mod },
            .{ .name = "vort", .module = vort_mod },
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

    const upload_example = b.addExecutable(.{
        .name = "upload",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/upload.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
                .{ .name = "netz", .module = netz_mod },
            },
        }),
    });
    b.installArtifact(upload_example);
    const run_upload_example = b.addRunArtifact(upload_example);
    const run_upload_step = b.step(
        "run-upload",
        "Run the streaming upload example",
    );
    run_upload_step.dependOn(&run_upload_example.step);

    const examples_step = b.step("examples", "Build all examples");
    examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);
    examples_step.dependOn(&b.addInstallArtifact(upload_example, .{}).step);

    const benchmark = b.addExecutable(.{
        .name = "router-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/router.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
            },
        }),
    });
    const run_benchmark = b.addRunArtifact(benchmark);
    const bench_step = b.step(
        "bench",
        "Run router microbenchmarks (use -Doptimize=ReleaseFast for real numbers)",
    );
    bench_step.dependOn(&run_benchmark.step);

    const server_benchmark = b.addExecutable(.{
        .name = "server-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
                .{ .name = "netz", .module = netz_mod },
            },
        }),
    });
    const run_server_benchmark = b.addRunArtifact(server_benchmark);
    const bench_server_step = b.step(
        "bench-server",
        "Run the HTTP/1 server throughput benchmark",
    );
    bench_server_step.dependOn(&run_server_benchmark.step);

    const h2_batch = b.option(
        u32,
        "h2-batch",
        "Concurrent streams per HTTP/2 benchmark batch (default 32)",
    ) orelse 32;
    const h2_batch_iterations = b.option(
        u32,
        "h2-batch-iterations",
        "HTTP/2 benchmark batch iterations (default 4000)",
    ) orelse 4_000;
    const h2_bench_options = b.addOptions();
    h2_bench_options.addOption(u32, "batch_size", h2_batch);
    h2_bench_options.addOption(u32, "batch_iterations", h2_batch_iterations);

    const h2_benchmark = b.addExecutable(.{
        .name = "h2-server-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/h2_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
                .{ .name = "netz", .module = netz_mod },
                .{ .name = "build_options", .module = h2_bench_options.createModule() },
            },
        }),
    });
    const run_h2_benchmark = b.addRunArtifact(h2_benchmark);
    const bench_h2_step = b.step(
        "bench-h2",
        "Run the HTTP/2 sequential and batched throughput benchmark",
    );
    bench_h2_step.dependOn(&run_h2_benchmark.step);

    const static_benchmark = b.addExecutable(.{
        .name = "static-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/static.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
                .{ .name = "netz", .module = netz_mod },
            },
        }),
    });
    const run_static_benchmark = b.addRunArtifact(static_benchmark);
    const bench_static_step = b.step(
        "bench-static",
        "Run the static-file handler benchmark",
    );
    bench_static_step.dependOn(&run_static_benchmark.step);

    const middleware_benchmark = b.addExecutable(.{
        .name = "middleware-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/middleware.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
                .{ .name = "netz", .module = netz_mod },
            },
        }),
    });
    const run_middleware_benchmark = b.addRunArtifact(middleware_benchmark);
    const bench_middleware_step = b.step(
        "bench-middleware",
        "Run the middleware-chain overhead benchmark",
    );
    bench_middleware_step.dependOn(&run_middleware_benchmark.step);

    const hello_server = b.addExecutable(.{
        .name = "hello-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/hello_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
                .{ .name = "netz", .module = netz_mod },
            },
        }),
    });
    const install_hello_server = b.addInstallArtifact(hello_server, .{});
    const build_hello_server_step = b.step(
        "build-hello-server",
        "Build the minimal hello-world server used for framework comparisons",
    );
    build_hello_server_step.dependOn(&install_hello_server.step);

    const accept_benchmark = b.addExecutable(.{
        .name = "accept-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/accept.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
            },
        }),
    });
    const run_accept_benchmark = b.addRunArtifact(accept_benchmark);
    const bench_accept_step = b.step(
        "bench-accept",
        "Run the Accept negotiation benchmark",
    );
    bench_accept_step.dependOn(&run_accept_benchmark.step);

    const h3_batch = b.option(
        u32,
        "h3-batch",
        "Concurrent streams per HTTP/3 benchmark batch (default 32)",
    ) orelse 32;
    const h3_batch_iterations = b.option(
        u32,
        "h3-batch-iterations",
        "HTTP/3 benchmark batch iterations (default 1000)",
    ) orelse 1_000;
    const h3_poll_us = b.option(
        u32,
        "h3-poll-us",
        "HTTP/3 handler poll interval override in microseconds (0 uses the weft default)",
    ) orelse 0;
    const h3_warmup = b.option(
        u32,
        "h3-warmup",
        "HTTP/3 benchmark batch warmup iterations (default 100)",
    ) orelse 100;
    const h3_bench_options = b.addOptions();
    h3_bench_options.addOption(u32, "batch_size", h3_batch);
    h3_bench_options.addOption(u32, "batch_iterations", h3_batch_iterations);
    h3_bench_options.addOption(u32, "poll_us", h3_poll_us);
    h3_bench_options.addOption(u32, "warmup_iterations", h3_warmup);

    const h3_benchmark = b.addExecutable(.{
        .name = "h3-server-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/h3_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft_mod },
                .{ .name = "netz", .module = netz_mod },
                .{ .name = "build_options", .module = h3_bench_options.createModule() },
            },
        }),
    });
    const run_h3_benchmark = b.addRunArtifact(h3_benchmark);
    const bench_h3_step = b.step(
        "bench-h3",
        "Run the HTTP/3 sequential and batched throughput benchmark",
    );
    bench_h3_step.dependOn(&run_h3_benchmark.step);
}
