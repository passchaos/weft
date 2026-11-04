//! Middleware-chain overhead benchmark.
//!
//! Measures weft's application-layer cost with a fixed arena and no I/O:
//! router match, middleware chain, and a tiny handler. Transport framing and
//! socket work are excluded, so the numbers isolate what weft adds on top of
//! netz.

const std = @import("std");
const netz = @import("netz");
const weft = @import("weft");

const iterations: usize = 200_000;

fn home(ctx: *weft.Ctx) anyerror!void {
    try ctx.text("ok");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const request_id_middleware = weft.handler(weft.middleware.requestId);
    var metrics_middleware = weft.middleware.Metrics{};
    var etag_middleware = weft.middleware.Etag{};
    var compress_middleware = weft.middleware.Compress{};

    try bench(
        allocator,
        io,
        "baseline (handler only)",
        &.{},
    );
    try bench(
        allocator,
        io,
        "requestId",
        &.{request_id_middleware},
    );
    try bench(
        allocator,
        io,
        "Metrics",
        &.{metrics_middleware.handler()},
    );
    try bench(
        allocator,
        io,
        "Etag",
        &.{etag_middleware.handler()},
    );
    try bench(
        allocator,
        io,
        "Compress",
        &.{compress_middleware.handler()},
    );
    try bench(
        allocator,
        io,
        "requestId+Metrics+Etag+Compress",
        &.{
            request_id_middleware,
            metrics_middleware.handler(),
            etag_middleware.handler(),
            compress_middleware.handler(),
        },
    );
}

fn bench(
    allocator: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
    middleware: []const weft.Handler,
) !void {
    const arena_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(arena_buffer);

    var request = netz.http1.Request{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var checksum: usize = 0;
    var index: usize = 0;
    const start = std.Io.Timestamp.now(io, .awake);
    while (index < iterations) : (index += 1) {
        var fixed = std.heap.FixedBufferAllocator.init(arena_buffer);
        const arena = fixed.allocator();
        var ctx = weft.Ctx{
            .app = undefined,
            .io = io,
            .arena = arena,
            .limits = .{},
            .request = &request,
            .response = weft.Response.init(arena, 64 * 1024),
            .middleware = middleware,
            .final_handler = weft.handler(home),
        };
        try ctx.run();
        checksum += ctx.response.body.len;
    }
    const elapsed = start.untilNow(io, .awake);
    std.mem.doNotOptimizeAway(checksum);

    const elapsed_ns = @as(f64, @floatFromInt(elapsed.nanoseconds));
    const count = @as(f64, @floatFromInt(iterations));
    std.debug.print(
        "middleware {s}: iterations={d} {d:.1} ns/request {d:.0} requests/s\n",
        .{
            label,
            iterations,
            elapsed_ns / count,
            count / (elapsed_ns / std.time.ns_per_s),
        },
    );
}
