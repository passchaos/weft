const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("build/helpers.zig");

// weft pins the exact Zig version because the std.Io and std.Build APIs it
// depends on are still changing between patch releases. Update this constant
// and build.zig.zon together when moving to a new toolchain.
const required_zig_version = "0.16.0";

const Import = helpers.Import;
const Builder = helpers.Builder;

pub fn build(b: *std.Build) void {
    comptime {
        if (!std.mem.eql(u8, builtin.zig_version_string, required_zig_version)) {
            @compileError(
                "weft pins Zig " ++ required_zig_version ++
                    " exactly because std.Io and std.Build are still changing; " ++
                    "update build.zig and build.zig.zon together (found " ++
                    builtin.zig_version_string ++ ")",
            );
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
    const zio_backend = b.option(
        []const u8,
        "zio-backend",
        "zio event loop backend: poll, linux, epoll, kqueue, io_uring, or iocp",
    );

    const netz_dep = b.dependency("netz", .{
        .target = target,
        .optimize = optimize,
        .scheduling = scheduling orelse "work_stealing",
        .@"zio-backend" = zio_backend,
    });
    const netz_mod = netz_dep.module("netz");
    const vort_dep = b.dependency("vort", .{
        .target = target,
        .optimize = optimize,
    });
    const vort_mod = vort_dep.module("vort");
    const kron_dep = b.dependency("kron", .{
        .target = target,
        .optimize = optimize,
    });
    const kron_mod = kron_dep.module("kron");

    const weft_mod = b.addModule("weft", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "netz", .module = netz_mod },
            .{ .name = "vort", .module = vort_mod },
            .{ .name = "kron", .module = kron_mod },
        },
    });

    const weft_imports = [_]Import{.{ .name = "weft", .module = weft_mod }};
    const weft_netz_imports = [_]Import{
        .{ .name = "weft", .module = weft_mod },
        .{ .name = "netz", .module = netz_mod },
    };
    const weft_netz_kron_imports = [_]Import{
        .{ .name = "weft", .module = weft_mod },
        .{ .name = "netz", .module = netz_mod },
        .{ .name = "kron", .module = kron_mod },
    };
    const netz_kron_imports = [_]Import{
        .{ .name = "netz", .module = netz_mod },
        .{ .name = "kron", .module = kron_mod },
    };

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
            .imports = &weft_imports,
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

    const check_step = b.step(
        "check",
        "Verify formatting and run the full test suite",
    );
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "test", "bench", "examples", "build", "build.zig" },
        .check = true,
    });
    check_step.dependOn(&fmt.step);
    check_step.dependOn(test_step);

    const ctx = Builder{
        .b = b,
        .target = target,
        .optimize = optimize,
        .examples_step = b.step("examples", "Build all examples"),
    };

    const hello = ctx.example(
        "hello",
        "examples/hello.zig",
        &weft_netz_imports,
    );
    ctx.run("run-hello", "Run the hello example", hello);
    const logging_example = ctx.example(
        "logging",
        "examples/logging.zig",
        &weft_netz_kron_imports,
    );
    ctx.run("run-logging", "Run the structured logging example", logging_example);
    const upload = ctx.example(
        "upload",
        "examples/upload.zig",
        &weft_netz_imports,
    );
    ctx.run("run-upload", "Run the streaming upload example", upload);
    const agent = ctx.example(
        "agent",
        "examples/agent.zig",
        &weft_netz_imports,
    );
    ctx.run("run-agent", "Run the OpenAPI + MCP agent example", agent);

    ctx.bench(
        "bench",
        "router-bench",
        "bench/router.zig",
        "Run router microbenchmarks (use -Doptimize=ReleaseFast for real numbers)",
        &weft_imports,
    );
    ctx.bench(
        "bench-server",
        "server-bench",
        "bench/server.zig",
        "Run the HTTP/1 server throughput benchmark",
        &weft_netz_imports,
    );

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
    const h2_options = b.addOptions();
    h2_options.addOption(u32, "batch_size", h2_batch);
    h2_options.addOption(u32, "batch_iterations", h2_batch_iterations);
    const h2_imports = [_]Import{
        .{ .name = "weft", .module = weft_mod },
        .{ .name = "netz", .module = netz_mod },
        .{ .name = "build_options", .module = h2_options.createModule() },
    };
    ctx.bench(
        "bench-h2",
        "h2-server-bench",
        "bench/h2_server.zig",
        "Run the HTTP/2 sequential and batched throughput benchmark",
        &h2_imports,
    );

    ctx.bench(
        "bench-static",
        "static-bench",
        "bench/static.zig",
        "Run the static-file handler benchmark",
        &weft_netz_imports,
    );
    ctx.bench(
        "bench-middleware",
        "middleware-bench",
        "bench/middleware.zig",
        "Run the middleware-chain overhead benchmark",
        &weft_netz_imports,
    );
    ctx.buildBench(
        "build-hello-server",
        "hello-server",
        "bench/hello_server.zig",
        "Build the minimal hello-world server used for framework comparisons",
        &weft_netz_imports,
    );
    ctx.buildBench(
        "build-h2-hello-server",
        "h2-hello-server",
        "bench/h2_hello_server.zig",
        "Build the minimal h2c hello-world server used for framework comparisons",
        &weft_netz_imports,
    );
    ctx.bench(
        "bench-accept",
        "accept-bench",
        "bench/accept.zig",
        "Run the Accept negotiation benchmark",
        &weft_imports,
    );
    ctx.bench(
        "bench-logging",
        "logging-bench",
        "bench/logging.zig",
        "Measure the structured access-log producer cost through kron",
        &netz_kron_imports,
    );

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
    const h3_options = b.addOptions();
    h3_options.addOption(u32, "batch_size", h3_batch);
    h3_options.addOption(u32, "batch_iterations", h3_batch_iterations);
    h3_options.addOption(u32, "poll_us", h3_poll_us);
    h3_options.addOption(u32, "warmup_iterations", h3_warmup);
    const h3_imports = [_]Import{
        .{ .name = "weft", .module = weft_mod },
        .{ .name = "netz", .module = netz_mod },
        .{ .name = "build_options", .module = h3_options.createModule() },
    };
    ctx.bench(
        "bench-h3",
        "h3-server-bench",
        "bench/h3_server.zig",
        "Run the HTTP/3 sequential and batched throughput benchmark",
        &h3_imports,
    );
    ctx.buildBench(
        "build-h3-bench",
        "h3-server-bench",
        "bench/h3_server.zig",
        "Build the HTTP/3 benchmark binary without running it",
        &h3_imports,
    );
}
