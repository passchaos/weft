const std = @import("std");
const netz = @import("netz");
const weft = @import("weft");

const App = struct {};

fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("ok");
}

fn serveServer(server: *weft.Http2Server(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.debug.print("server failed: {s}\n", .{@errorName(err)});
            return;
        },
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const sequential_iterations: usize = 100_000;
    const batch_size: usize = 8;
    const batch_iterations: usize = 8_000;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Http2Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 4096,
                .max_http2_concurrent_streams = @intCast(batch_size),
            },
            .max_connections = 1,
            .max_requests_per_connection = 1_000_000,
            .max_concurrent_handlers = batch_size,
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    var connection = try netz.http2.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer connection.close();

    var index: usize = 0;
    while (index < 100) : (index += 1) {
        var response = try connection.request(.{});
        defer response.deinit(allocator);
    }

    var started = std.Io.Timestamp.now(io, .awake);
    index = 0;
    while (index < sequential_iterations) : (index += 1) {
        var response = try connection.request(.{});
        defer response.deinit(allocator);
        if (response.status != 200) return error.BenchmarkStatus;
    }
    var elapsed = started.untilNow(io, .awake);
    printResult("server h2 sequential", sequential_iterations, elapsed);

    var requests: [batch_size]netz.http2.runtime.RequestOptions = undefined;
    for (&requests) |*request| request.* = .{};
    var responses: [batch_size]netz.http2.runtime.OwnedResponse = undefined;

    index = 0;
    while (index < 100) : (index += 1) {
        try connection.requestBatchInto(&requests, &responses);
        for (&responses) |*response| response.deinit(allocator);
    }

    started = std.Io.Timestamp.now(io, .awake);
    index = 0;
    while (index < batch_iterations) : (index += 1) {
        try connection.requestBatchInto(&requests, &responses);
        for (&responses) |*response| {
            if (response.status != 200) return error.BenchmarkStatus;
            response.deinit(allocator);
        }
    }
    elapsed = started.untilNow(io, .awake);
    printResult(
        "server h2 batched",
        batch_size * batch_iterations,
        elapsed,
    );

    server.stop();
    try group.await(io);
}

fn printResult(label: []const u8, requests: usize, elapsed: std.Io.Duration) void {
    const elapsed_ns = @as(f64, @floatFromInt(elapsed.nanoseconds));
    const count = @as(f64, @floatFromInt(requests));
    std.debug.print(
        "{s}: requests={d} {d:.1} ns/request {d:.0} requests/s\n",
        .{
            label,
            requests,
            elapsed_ns / count,
            count / (elapsed_ns / std.time.ns_per_s),
        },
    );
}
