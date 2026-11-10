const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const etagRoute = support.etagRoute;
const hello = support.hello;
const home = support.home;
const serveServer = support.serveServer;

test "package: ETag and compression produce representation-specific validators" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var etag = weft.middleware.Etag{};
    var compress = weft.middleware.Compress{ .min_bytes = 1 };
    var middleware = [_]weft.Handler{
        etag.handler(),
        compress.handler(),
    };
    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .middleware = &middleware,
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/etag", etagRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/etag",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    const gzip_headers = [_]netz.http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var encoded = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .headers = &gzip_headers },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer encoded.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), encoded.response.status);
    try std.testing.expectEqualStrings(
        "gzip",
        encoded.response.header("content-encoding").?,
    );
    try std.testing.expect(encoded.response.header("vary") != null);
    const encoded_tag = encoded.response.header("etag").?;

    const conditional_headers = [_]netz.http1.Header{
        .{ .name = "Accept-Encoding", .value = "gzip" },
        .{ .name = "If-None-Match", .value = encoded_tag },
    };
    var conditional = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .headers = &conditional_headers },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer conditional.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 304), conditional.response.status);
    try std.testing.expectEqualStrings("", conditional.response.body);
    try std.testing.expectEqualStrings(
        encoded_tag,
        conditional.response.header("etag").?,
    );

    var identity = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer identity.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), identity.response.status);
    try std.testing.expect(identity.response.header("content-encoding") == null);
    const identity_tag = identity.response.header("etag").?;
    try std.testing.expect(!std.mem.eql(u8, encoded_tag, identity_tag));

    server.stop();
    try group.await(io);
}

test "package: ETag middleware answers conditional GET" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var etag = weft.middleware.Etag{};
    var middleware = [_]weft.Handler{etag.handler()};
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
            .middleware = &middleware,
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/etag", etagRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/etag",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var first = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer first.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), first.response.status);
    try std.testing.expectEqualStrings("hello", first.response.body);
    const tag = first.response.header("etag").?;

    const headers = [_]netz.http1.Header{.{
        .name = "If-None-Match",
        .value = tag,
    }};
    var second = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .headers = &headers },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer second.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 304), second.response.status);
    try std.testing.expectEqualStrings("", second.response.body);
    try std.testing.expectEqualStrings(tag, second.response.header("etag").?);

    server.stop();
    try group.await(io);
}

test "package: metrics endpoint renders Prometheus text" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    const MetricsRoute = struct {
        metrics: *weft.middleware.Metrics,

        fn handle(self: *@This(), ctx: *weft.Ctx) anyerror!void {
            var buffer: [2048]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try self.metrics.snapshot().writePrometheus(&writer, "weft");
            try ctx.setHeader(
                "Content-Type",
                "text/plain; version=0.0.4; charset=utf-8",
            );
            try ctx.text(try ctx.arena.dupe(u8, writer.buffered()));
        }
    };

    var counters = weft.middleware.Metrics{};
    var metrics_route = MetricsRoute{ .metrics = &counters };

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .middleware = &.{counters.handler()},
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/", home, .{});
    try server.router().addRaw(
        .GET,
        "/metrics",
        weft.withContext(MetricsRoute, &metrics_route, MetricsRoute.handle),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{server.address().ip4.port},
    );
    defer allocator.free(base);

    const home_uri = try std.fmt.allocPrint(allocator, "{s}/", .{base});
    defer allocator.free(home_uri);
    var home_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        home_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer home_response.deinit(allocator);

    const metrics_uri = try std.fmt.allocPrint(allocator, "{s}/metrics", .{base});
    defer allocator.free(metrics_uri);
    var metrics_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        metrics_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer metrics_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        metrics_response.response.status,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        metrics_response.response.header("content-type").?,
        "text/plain",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        metrics_response.response.body,
        "# TYPE weft_requests_total counter",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        metrics_response.response.body,
        "weft_responses_total{status_class=\"2xx\"}",
    ) != null);

    server.stop();
    try group.await(io);
}

test "package: handlers negotiate the Accept header" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    const negotiate = struct {
        fn handle(ctx: *weft.Ctx) anyerror!void {
            if (ctx.accepts("application/json")) {
                return ctx.json(.{ .kind = "json" });
            }
            try ctx.text("plain");
        }
    };

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
        },
        .{},
    );
    defer server.deinit();
    try server.router().addRaw(
        .GET,
        "/negotiate",
        weft.handler(negotiate.handle),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/negotiate",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    const json_headers = [_]netz.http1.Header{.{
        .name = "Accept",
        .value = "application/json",
    }};
    var json_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .headers = &json_headers },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer json_response.deinit(allocator);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"json\"}",
        json_response.response.body,
    );

    const text_headers = [_]netz.http1.Header{.{
        .name = "Accept",
        .value = "text/plain",
    }};
    var text_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .headers = &text_headers },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer text_response.deinit(allocator);
    try std.testing.expectEqualStrings("plain", text_response.response.body);

    var any_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer any_response.deinit(allocator);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"json\"}",
        any_response.response.body,
    );

    server.stop();
    try group.await(io);
}
