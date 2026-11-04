const std = @import("std");
const netz = @import("netz");
const weft = @import("weft");

const App = struct {};

fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("ok");
}

fn serveServer(server: *weft.Http3Server(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.debug.print("server failed: {s}\n", .{@errorName(err)});
            return;
        },
    };
}

const BatchCtx = struct {
    allocator: std.mem.Allocator,
    count: usize = 0,
    ok: bool = true,

    fn onResult(
        raw: *anyopaque,
        _: usize,
        result: netz.http3.runtime.BatchOwnedHandshakeResponseResult,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (result) {
            .response => |value| {
                var response = value;
                defer response.deinit(self.allocator);
                self.count += 1;
                if (response.response.status != 200) self.ok = false;
            },
            .err => self.ok = false,
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const sequential_iterations: usize = 10_000;
    const batch_size: usize = 32;
    const batch_iterations: usize = 1_000;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    const server_cid = [_]u8{ 0xec, 0xed, 0xee, 0xef };
    const original_dcid = [_]u8{ 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7 };
    const client_cid = [_]u8{ 0xe8, 0xe9, 0xea, 0xeb };

    var server = try weft.Http3Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 512 * 1024,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 4096,
            },
            .max_connections = 1,
            .max_requests_per_connection = 1_000_000,
            .max_concurrent_streams = batch_size,
            .max_concurrent_handlers = batch_size,
            .accept_timeout = .fromMilliseconds(500),
            .idle_timeout = .fromMilliseconds(100),
            .quic_limits = .{
                .max_datagram_size = 4096,
                .max_frames_per_datagram = 8,
            },
            .handshake = .{
                .local_connection_id = &server_cid,
                .random = [_]u8{0xe2} ** 32,
                .x25519_secret_key = [_]u8{0xe4} ** 32,
            },
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    std.debug.print(
        "h3 bench connecting to port {d}\n",
        .{server.address().ip4.port},
    );
    var client = try netz.http3.runtime.HandshakeClient.connect(
        allocator,
        io,
        .{ .ip4 = .loopback(0) },
        server.address(),
        .{
            .quic = .{
                .max_datagram_size = 4096,
                .max_frames_per_datagram = 8,
            },
        },
        .{
            .handshake = .{
                .original_destination_connection_id = &original_dcid,
                .local_connection_id = &client_cid,
                .server_name = "localhost",
                .random = [_]u8{0xe1} ** 32,
                .x25519_secret_key = [_]u8{0xe3} ** 32,
            },
        },
    );
    defer client.deinit();

    var index: usize = 0;
    while (index < 100) : (index += 1) {
        var response = try client.request(.{
            .method = "GET",
            .path = "/",
            .authority = "localhost",
        });
        defer response.deinit(allocator);
    }

    var started = std.Io.Timestamp.now(io, .awake);
    index = 0;
    while (index < sequential_iterations) : (index += 1) {
        var response = try client.request(.{
            .method = "GET",
            .path = "/",
            .authority = "localhost",
        });
        defer response.deinit(allocator);
        if (response.response.status != 200) return error.BenchmarkStatus;
    }
    var elapsed = started.untilNow(io, .awake);
    printResult("server h3 sequential", sequential_iterations, elapsed);

    var requests: [batch_size]netz.http3.Request = undefined;
    for (&requests) |*request| {
        request.* = .{
            .method = "GET",
            .path = "/",
            .authority = "localhost",
        };
    }
    var deadlines: [batch_size]?std.Io.Clock.Timestamp = undefined;
    for (&deadlines) |*deadline| deadline.* = null;
    var context = BatchCtx{ .allocator = allocator };

    index = 0;
    while (index < 100) : (index += 1) {
        context.count = 0;
        context.ok = true;
        try client.requestBatchWithPerStreamDeadlines(
            &requests,
            &deadlines,
            .{
                .context = &context,
                .on_result = BatchCtx.onResult,
            },
        );
    }

    started = std.Io.Timestamp.now(io, .awake);
    index = 0;
    while (index < batch_iterations) : (index += 1) {
        context.count = 0;
        context.ok = true;
        try client.requestBatchWithPerStreamDeadlines(
            &requests,
            &deadlines,
            .{
                .context = &context,
                .on_result = BatchCtx.onResult,
            },
        );
        if (!context.ok or context.count != batch_size) {
            return error.BenchmarkStatus;
        }
    }
    elapsed = started.untilNow(io, .awake);
    printResult("server h3 batched", batch_size * batch_iterations, elapsed);

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
