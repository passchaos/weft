const std = @import("std");
const netz = @import("netz");
const weft = @import("weft");

const App = struct {};

fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("ok");
}

fn serveServer(server: *weft.Server(App)) std.Io.Cancelable!void {
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
    const iterations: usize = 200_000;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 4096,
            },
            .max_connections = 1,
            .max_requests_per_connection = 1_000_000,
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    var client = try netz.http1.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();

    var index: usize = 0;
    while (index < 100) : (index += 1) {
        var response = try client.request(.{
            .method = .GET,
            .target = "/",
            .host = "localhost",
        });
        defer response.deinit(allocator);
    }

    const started = std.Io.Timestamp.now(io, .awake);
    index = 0;
    while (index < iterations) : (index += 1) {
        var response = try client.request(.{
            .method = .GET,
            .target = "/",
            .host = "localhost",
        });
        defer response.deinit(allocator);
        if (response.response.status != 200) return error.BenchmarkStatus;
    }
    const elapsed = started.untilNow(io, .awake);

    const elapsed_ns = @as(f64, @floatFromInt(elapsed.nanoseconds));
    const count = @as(f64, @floatFromInt(iterations));
    std.debug.print(
        "server http1: requests={d} {d:.1} ns/request {d:.0} requests/s\n",
        .{
            iterations,
            elapsed_ns / count,
            count / (elapsed_ns / std.time.ns_per_s),
        },
    );

    server.stop();
    try group.await(io);
}
