//! Streaming upload, streaming multipart, SSE, and Prometheus metrics.
//!
//! The example starts a server, drives one request per route, prints the
//! results, and stops. Run it with `zig build run-upload`.

const std = @import("std");
const netz = @import("netz");
const weft = @import("weft");

/// The server stores the application context by value, so shared mutable
/// state lives behind a pointer that every copy of `App` sees.
const App = struct {
    metrics: *weft.middleware.Metrics,
};

fn upload(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const reader = ctx.bodyReader() orelse
        return error.NotStreamingRoute;
    var total: usize = 0;
    while (try reader.next()) |chunk| total += chunk.len;
    try ctx.json(.{ .bytes = total });
}

fn multipartUpload(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    var stream = try ctx.multipartStream();
    defer stream.deinit();
    var parts: usize = 0;
    var bytes: usize = 0;
    while (try stream.nextPart()) |part| {
        parts += 1;
        while (try part.data.next()) |chunk| bytes += chunk.len;
    }
    try ctx.json(.{ .parts = parts, .bytes = bytes });
}

fn sseBody(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
    try writer.write("id: 1\nevent: tick\ndata: hello\n\n");
}

fn events(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.sse(.{ .write_fn = sseBody });
}

fn metrics(app: *App, ctx: *weft.Ctx) anyerror!void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try app.metrics.snapshot().writePrometheus(&writer, "weft");
    try ctx.setHeader(
        "Content-Type",
        "text/plain; version=0.0.4; charset=utf-8",
    );
    try ctx.text(try ctx.arena.dupe(u8, writer.buffered()));
}

fn serveServer(server: *weft.Server(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn(
                "server failed: {s}",
                .{@errorName(err)},
            );
            return;
        },
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var metrics_state = weft.middleware.Metrics{};
    const app = App{ .metrics = &metrics_state };
    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 16 * 1024,
                .max_body_bytes = 512 * 1024,
                .max_request_arena_bytes = 128 * 1024,
                .max_response_bytes = 64 * 1024,
                .max_streaming_window_bytes = 32 * 1024,
            },
            .max_connections = 4,
            .middleware = &.{
                weft.handler(weft.middleware.requestId),
                metrics_state.handler(),
            },
        },
        app,
    );
    defer server.deinit();

    var router = server.router();
    try router.post("/upload", upload, .{ .streaming = true });
    try router.post(
        "/upload/multipart",
        multipartUpload,
        .{ .streaming = true },
    );
    try router.get("/events", events, .{});
    try router.get("/metrics", metrics, .{});

    const address = server.address();
    std.debug.print("weft listening on http://{f}\n", .{address});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{address.ip4.port},
    );
    defer allocator.free(base);

    const payload = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'x');

    const upload_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload",
        .{base},
    );
    defer allocator.free(upload_uri);
    try request(
        allocator,
        io,
        upload_uri,
        .{ .method = .POST, .body = payload },
    );

    const multipart_body = try std.fmt.allocPrint(
        allocator,
        "--weft\r\n" ++
            "Content-Disposition: form-data; name=\"field\"\r\n" ++
            "\r\n" ++
            "value\r\n" ++
            "--weft\r\n" ++
            "Content-Disposition: form-data; name=\"file\"; filename=\"a.bin\"\r\n" ++
            "\r\n" ++
            "{s}\r\n" ++
            "--weft--\r\n",
        .{payload},
    );
    defer allocator.free(multipart_body);
    const multipart_headers = [_]netz.http1.Header{.{
        .name = "Content-Type",
        .value = "multipart/form-data; boundary=weft",
    }};
    const multipart_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload/multipart",
        .{base},
    );
    defer allocator.free(multipart_uri);
    try request(allocator, io, multipart_uri, .{
        .method = .POST,
        .headers = &multipart_headers,
        .body = multipart_body,
    });

    const events_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/events",
        .{base},
    );
    defer allocator.free(events_uri);
    try request(allocator, io, events_uri, .{});

    const metrics_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/metrics",
        .{base},
    );
    defer allocator.free(metrics_uri);
    try request(allocator, io, metrics_uri, .{});

    server.stop();
    try group.await(io);
}

fn request(
    allocator: std.mem.Allocator,
    io: std.Io,
    uri: []const u8,
    options: netz.http1.runtime.RequestOptions,
) !void {
    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        options,
        .{ .max_head_bytes = 16 * 1024, .max_body_bytes = 1024 * 1024 },
    );
    defer response.deinit(allocator);
    std.debug.print(
        "{s} -> {d}: {s}\n",
        .{ uri, response.response.status, response.response.body },
    );
}
