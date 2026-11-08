const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;

const App = struct {};

fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("hello from weft");
}

fn upload(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const form = try ctx.multipart();
    const field = form.part("field") orelse {
        ctx.setStatus(400);
        return ctx.text("Missing field");
    };
    const file = form.part("file") orelse {
        ctx.setStatus(400);
        return ctx.text("Missing file");
    };
    try ctx.json(.{
        .field = field.data,
        .filename = file.filename orelse "",
        .size = file.data.len,
    });
}

fn websocketEcho(
    _: ?*anyopaque,
    session: *weft.WebSocketSession,
) anyerror!void {
    var message = try session.receiveMessage();
    defer session.deinitMessage(&message);
    try session.sendText(message.payload);
}

fn websocketRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.upgradeWebSocket(.{ .run_fn = websocketEcho });
}

fn websocketCompressedRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.upgradeWebSocket(.{
        .run_fn = websocketEcho,
        .compression = true,
    });
}

fn clientAddressText(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const address = ctx.clientAddress() orelse return ctx.text("none");
    try ctx.text(try std.fmt.allocPrint(ctx.arena, "{f}", .{address}));
}

fn deadlineInfo(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.json(.{
        .has_deadline = ctx.deadline() != null,
        .expired = ctx.expired(),
    });
}

fn customNotFound(ctx: *weft.Ctx) anyerror!void {
    const failure = ctx.get(weft.RouteFailure) orelse
        return ctx.internalError();
    const kind = switch (failure) {
        .not_found => "not_found",
        else => "other",
    };
    try ctx.json(.{ .custom = kind, .status = ctx.response.status });
}

fn customMethodNotAllowed(ctx: *weft.Ctx) anyerror!void {
    const failure = ctx.get(weft.RouteFailure) orelse
        return ctx.internalError();
    const allow = switch (failure) {
        .method_not_allowed => |allowed| allowed,
        else => return ctx.internalError(),
    };
    try ctx.json(.{
        .custom = "method_not_allowed",
        .allow = try allow.value(ctx.arena),
    });
}

fn clientInfo(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.json(.{
        .protocol = @tagName(ctx.protocol()),
        .has_address = ctx.clientAddress() != null,
        .tls = ctx.isTls(),
    });
}

fn cookiesRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.setCookie(.{
        .name = "session",
        .value = "abc",
        .path = "/",
        .http_only = true,
        .same_site = .lax,
    });
    try ctx.setCookie(.{
        .name = "__Host-theme",
        .value = "dark",
        .path = "/",
        .secure = true,
    });
    try ctx.text("ok");
}

fn certificateCount(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.json(.{ .certs = ctx.peerCertificates().len });
}

fn etagRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("hello");
}

fn trailerRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("body");
    try ctx.addTrailer("X-Checksum", "abc");
}
fn trailerBody(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
    try writer.write("body");
}

fn bufferedTrailerEcho(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text(ctx.trailer("x-checksum") orelse "");
}

fn streamingTrailerEcho(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const reader = ctx.bodyReader().?;
    while (try reader.next()) |_| {}
    try ctx.text(ctx.trailer("x-checksum") orelse "");
}

fn streamingTrailerRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.addTrailer("X-Checksum", "abc");
    try ctx.stream(.{ .write_fn = trailerBody, .length = 4 });
}

fn hello(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const name = ctx.param("name") orelse "stranger";
    try ctx.json(.{
        .message = "hello",
        .name = name,
    });
}

const JsonPayload = struct {
    message: []const u8,
};

fn echoJson(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const payload = try ctx.bodyJson(JsonPayload);
    try ctx.json(.{ .message = payload.message });
}

fn echoBufferedBody(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text(ctx.body());
}

fn gzipAlloc(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    defer output.deinit();

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var encoder = try std.compress.flate.Compress.init(
        &output.writer,
        &window,
        .gzip,
        .default,
    );
    try encoder.writer.writeAll(body);
    try encoder.finish();
    return output.toOwnedSlice();
}

fn serveHttp2Server(
    server: *weft.Http2Server(App),
) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn("http2 server failed: {s}", .{@errorName(err)});
            return;
        },
    };
}

fn serveHttp3Server(
    server: *weft.Http3Server(App),
) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn("http3 server failed: {s}", .{@errorName(err)});
            return;
        },
    };
}

fn h2Header(
    response: *const netz.http2.runtime.OwnedResponse,
    name: []const u8,
) ?[]const u8 {
    for (response.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn h3Header(
    response: *const netz.http3.runtime.OwnedHandshakeResponse,
    name: []const u8,
) ?[]const u8 {
    for (response.response.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn serveServer(server: *weft.Server(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn("server failed: {s}", .{@errorName(err)});
            return;
        },
    };
}

test "package: router selects static, parameter, and wildcard routes" {
    const allocator = std.testing.allocator;
    var router = weft.Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *weft.Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/users/me", weft.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/users/:id", weft.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/assets/*", weft.handler(Dummy.handle), .{});

    const me = (try router.match(.GET, "/users/me", allocator)).?;
    defer allocator.free(me.params);
    try std.testing.expectEqualStrings("/users/me", me.route.pattern);

    const user = (try router.match(.GET, "/users/42", allocator)).?;
    defer allocator.free(user.params);
    try std.testing.expectEqualStrings("/users/:id", user.route.pattern);
    try std.testing.expectEqualStrings("42", user.params[0].value);

    const asset = (try router.match(.GET, "/assets/a/b", allocator)).?;
    defer allocator.free(asset.params);
    try std.testing.expectEqualStrings("a/b", asset.params[0].value);
}

test "package: middleware order, short-circuit, and locals" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const State = struct {
        fn before(ctx: *weft.Ctx) anyerror!void {
            try ctx.set(u32, 7);
            try ctx.next();
        }

        fn after(ctx: *weft.Ctx) anyerror!void {
            const value = ctx.get(u32) orelse 0;
            try ctx.setHeader("X-Test", "ok");
            _ = value;
            try ctx.next();
        }

        fn stop(ctx: *weft.Ctx) anyerror!void {
            ctx.setStatus(403);
            try ctx.text("stopped");
        }

        fn handler(ctx: *weft.Ctx) anyerror!void {
            const value = ctx.get(u32) orelse 0;
            try ctx.text(try std.fmt.allocPrint(
                ctx.arena,
                "value={d}",
                .{value},
            ));
        }
    };

    const response = weft.Response.init(arena.allocator(), 1024);
    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var context = weft.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response,
        .middleware = &.{
            weft.handler(State.before),
            weft.handler(State.after),
        },
        .final_handler = weft.handler(State.handler),
    };

    try context.run();
    try std.testing.expectEqualStrings("value=7", context.response.body);
    try std.testing.expect(context.response.hasHeader("x-test"));

    const stopped = weft.Response.init(arena.allocator(), 1024);
    var stopped_context = weft.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = stopped,
        .middleware = &.{weft.handler(State.stop)},
        .final_handler = weft.handler(State.handler),
    };
    try stopped_context.run();
    try std.testing.expectEqual(@as(u16, 403), stopped_context.response.status);
    try std.testing.expectEqualStrings("stopped", stopped_context.response.body);
}

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

test "package: end-to-end HTTP/1 request" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .max_requests_per_connection = 4,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/", home, .{});
    try router.get("/hello/:name", hello, .{});
    try router.get("/info", clientInfo, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/hello/weft",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "{\"message\":\"hello\",\"name\":\"weft\"}",
        response.response.body,
    );

    const info_uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/info",
        .{server.address().ip4.port},
    );
    defer allocator.free(info_uri);
    var info_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        info_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer info_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), info_response.response.status);
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"http_1_1\",\"has_address\":true,\"tls\":false}",
        info_response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: next may be called at most once per handler" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Bad = struct {
        fn twice(ctx: *weft.Ctx) anyerror!void {
            try ctx.next();
            try ctx.next();
        }

        fn final(ctx: *weft.Ctx) anyerror!void {
            try ctx.text("ok");
        }
    };

    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var context = weft.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = weft.Response.init(arena.allocator(), 1024),
        .middleware = &.{weft.handler(Bad.twice)},
        .final_handler = weft.handler(Bad.final),
    };

    try std.testing.expectError(error.NextNotAllowed, context.run());
    try std.testing.expectEqualStrings("ok", context.response.body);
}

test "package: query parameters are parsed" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/search?q=weft&lang=zh",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var context = weft.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .query = "q=weft&lang=zh",
        .response = weft.Response.init(arena.allocator(), 1024),
        .final_handler = weft.handler(struct {
            fn handle(ctx: *weft.Ctx) anyerror!void {
                try ctx.text(ctx.queryParam("q") orelse "missing");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings("weft", context.response.body);
}

fn slowHandler(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try std.Io.sleep(ctx.io, .fromMilliseconds(200), .awake);
    try ctx.text("slow");
}

const StreamHandlers = struct {
    fn fixed(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
        try writer.write("hello ");
        try writer.write("stream");
    }

    fn chunked(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
        try writer.write("chunked ");
        try writer.write("body");
    }

    fn fixedRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.setHeader("Content-Type", "text/plain; charset=utf-8");
        try ctx.stream(.{ .write_fn = fixed, .length = 12 });
    }

    fn chunkedRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.setHeader("Content-Type", "text/plain; charset=utf-8");
        try ctx.stream(.{ .write_fn = chunked });
    }

    fn oversizedRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.stream(.{ .write_fn = fixed, .length = 512 });
    }

    fn sse(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
        try weft.sse.write(writer, .{
            .id = "1",
            .event = "tick",
            .data = "first\nsecond",
        });
        try weft.sse.comment(writer, "keep-alive");
    }

    fn sseRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.sse(.{ .write_fn = sse });
    }

    fn uploadRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        const reader = ctx.bodyReader().?;
        var total: usize = 0;
        while (try reader.next()) |chunk| total += chunk.len;
        try ctx.json(.{ .bytes = total });
    }

    fn decodedUploadRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        const reader = if (try ctx.decodedReader()) |decoded|
            weft.BodyReader{ .decoded = decoded }
        else
            ctx.bodyReader().?;
        var total: usize = 0;
        while (try reader.next()) |chunk| total += chunk.len;
        try ctx.json(.{ .bytes = total });
    }

    fn multipartStreamRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        var stream = try ctx.multipartStream();
        defer stream.deinit();
        var field: []const u8 = "";
        var file_bytes: usize = 0;
        while (try stream.nextPart()) |part| {
            var total: usize = 0;
            while (try part.data.next()) |chunk| total += chunk.len;
            if (std.mem.eql(u8, part.name, "field")) {
                field = try ctx.arena.dupe(u8, part.name);
            } else if (std.mem.eql(u8, part.name, "file")) {
                file_bytes = total;
            }
        }
        try ctx.json(.{ .field = field, .file_bytes = file_bytes });
    }

    fn readBodyRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        const body = try ctx.readBody();
        try ctx.json(.{ .bytes = body.len });
    }

    /// Reports whether the adapter exposed the incremental reader, without
    /// dereferencing it. Streaming-route detection must ignore the query.
    fn streamingProbeRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.json(.{ .streaming = ctx.bodyReader() != null });
    }

    fn rejectUpload(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        ctx.setStatus(413);
        try ctx.text("too large");
    }
};

const MethodHandlers = struct {
    fn resource(ctx: *weft.Ctx) anyerror!void {
        try ctx.text("resource");
    }

    fn echo(ctx: *weft.Ctx) anyerror!void {
        try ctx.json(.{
            .name = ctx.param("name") orelse "",
            .q = ctx.queryParam("q") orelse "",
        });
    }

    fn tooManyHeaders(ctx: *weft.Ctx) anyerror!void {
        try ctx.setHeader("X-A", "a");
        try ctx.setHeader("X-B", "b");
        try ctx.setHeader("X-C", "c");
        try ctx.text("ok");
    }
};

test "package: 405, automatic OPTIONS, and HEAD fallback" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 2,
            .max_requests_per_connection = 4,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.addRaw(
        .GET,
        "/resource",
        weft.handler(MethodHandlers.resource),
        .{},
    );
    try router.addRaw(
        .POST,
        "/resource",
        weft.handler(MethodHandlers.resource),
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
    const uri = try std.fmt.allocPrint(allocator, "{s}/resource", .{base});
    defer allocator.free(uri);

    var put_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .method = .PUT },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer put_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 405), put_response.response.status);
    const allow = put_response.response.header("allow").?;
    try std.testing.expect(std.mem.indexOf(u8, allow, "GET") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "POST") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "OPTIONS") != null);

    var options_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .method = .OPTIONS },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer options_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 204),
        options_response.response.status,
    );
    try std.testing.expect(
        options_response.response.header("allow") != null,
    );

    var head_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .method = .HEAD },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer head_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), head_response.response.status);
    try std.testing.expectEqualStrings("", head_response.response.body);

    server.stop();
    try group.await(io);
}

test "package: HTTP/1 routes an absolute-form request target" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 2,
            .max_requests_per_connection = 4,
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/hello/:name", hello, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const address = server.address();
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var out_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buffer);
    try writer.interface.writeAll(
        "GET http://example.com/hello/absolute HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Connection: close\r\n\r\n",
    );
    try writer.interface.flush();

    var in_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buffer);
    var response_buffer: [8192]u8 = undefined;
    const response_len = try reader.interface.readSliceShort(&response_buffer);
    const response = response_buffer[0..response_len];
    try std.testing.expect(
        std.mem.indexOf(u8, response, "HTTP/1.1 200") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, response, "\"name\":\"absolute\"") != null,
    );

    server.stop();
    try group.await(io);
}

test "package: decoded params and query values" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 2,
        },
        .{},
    );
    defer server.deinit();

    try server.router().addRaw(
        .GET,
        "/hello/:name",
        weft.handler(MethodHandlers.echo),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/hello/a%20b?q=hello+world",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "{\"name\":\"a b\",\"q\":\"hello world\"}",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: malformed query encoding is a 400" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().addRaw(
        .GET,
        "/hello/:name",
        weft.handler(MethodHandlers.echo),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/hello/x?q=%zz",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 400), response.response.status);

    server.stop();
    try group.await(io);
}

test "package: global middleware covers 404 responses" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .middleware = &.{weft.handler(weft.middleware.serverHeader)},
        },
        .{},
    );
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/missing",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), response.response.status);
    try std.testing.expectEqualStrings(
        "weft",
        response.response.header("server").?,
    );

    server.stop();
    try group.await(io);
}

test "package: HTTP/1.0 responses mirror the request version" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .version = .http_1_0 },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(
        netz.http1.Version.http_1_0,
        response.response.version,
    );
    try std.testing.expectEqualStrings(
        "hello from weft",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: stop drains an idle keep-alive connection" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
                .request_head_timeout = .fromMilliseconds(100),
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const address = server.address();
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // Give the worker time to accept and block waiting for a request head.
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    server.stop();
    try group.await(io);
}

test "package: streaming responses support fixed, chunked, and HEAD" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 2,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/stream/fixed", StreamHandlers.fixedRoute, .{});
    try router.get("/stream/chunked", StreamHandlers.chunkedRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{server.address().ip4.port},
    );
    defer allocator.free(base);

    const fixed_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/stream/fixed",
        .{base},
    );
    defer allocator.free(fixed_uri);

    var fixed_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        fixed_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer fixed_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), fixed_response.response.status);
    try std.testing.expectEqualStrings(
        "hello stream",
        fixed_response.response.body,
    );

    var head_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        fixed_uri,
        .{ .method = .HEAD },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer head_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), head_response.response.status);
    try std.testing.expectEqualStrings("", head_response.response.body);
    try std.testing.expectEqualStrings(
        "12",
        head_response.response.header("content-length").?,
    );

    const chunked_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/stream/chunked",
        .{base},
    );
    defer allocator.free(chunked_uri);

    var chunked_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        chunked_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer chunked_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), chunked_response.response.status);
    try std.testing.expectEqualStrings(
        "chunked body",
        chunked_response.response.body,
    );
    try std.testing.expectEqualStrings(
        "chunked",
        chunked_response.response.header("transfer-encoding").?,
    );

    server.stop();
    try group.await(io);
}

test "package: server-sent events set stream headers and format fields" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/events", StreamHandlers.sseRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/events",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "text/event-stream",
        response.response.header("content-type").?,
    );
    try std.testing.expectEqualStrings(
        "no-cache",
        response.response.header("cache-control").?,
    );
    try std.testing.expectEqualStrings(
        "id: 1\nevent: tick\ndata: first\ndata: second\n\n: keep-alive\n\n",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: HTTP/1 response trailers honor TE" {
    const allocator = std.testing.allocator;

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
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/trailers", trailerRoute, .{});
    try server.router().get(
        "/trailers-stream",
        streamingTrailerRoute,
        .{},
    );
    try server.router().post(
        "/upload-trailers",
        streamingTrailerEcho,
        .{ .streaming = true },
    );
    try server.router().post("/upload-buffered-trailers", bufferedTrailerEcho, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/trailers",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    const te_headers = [_]netz.http1.Header{.{
        .name = "TE",
        .value = "trailers",
    }};
    var accepted = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .headers = &te_headers },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), accepted.response.status);
    try std.testing.expectEqualStrings("body", accepted.response.body);
    try std.testing.expectEqual(@as(usize, 1), accepted.response.trailers.len);
    try std.testing.expect(std.ascii.eqlIgnoreCase(
        "X-Checksum",
        accepted.response.trailers[0].name,
    ));
    try std.testing.expectEqualStrings(
        "abc",
        accepted.response.trailers[0].value,
    );

    const stream_uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/trailers-stream",
        .{server.address().ip4.port},
    );
    defer allocator.free(stream_uri);
    var streamed = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        stream_uri,
        .{ .headers = &te_headers },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer streamed.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), streamed.response.status);
    try std.testing.expectEqualStrings("body", streamed.response.body);
    try std.testing.expectEqual(@as(usize, 1), streamed.response.trailers.len);
    try std.testing.expectEqualStrings("abc", streamed.response.trailers[0].value);

    var refused = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer refused.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), refused.response.status);
    try std.testing.expectEqualStrings("body", refused.response.body);
    try std.testing.expectEqual(@as(usize, 0), refused.response.trailers.len);

    const upload_uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/upload-trailers",
        .{server.address().ip4.port},
    );
    defer allocator.free(upload_uri);
    const request_trailers = [_]netz.http1.Header{.{
        .name = "X-Checksum",
        .value = "abc",
    }};
    var upload_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        upload_uri,
        .{
            .method = .POST,
            .body = "payload",
            .trailers = &request_trailers,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer upload_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), upload_response.response.status);
    try std.testing.expectEqualStrings("abc", upload_response.response.body);

    const buffered_trailer_uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/upload-buffered-trailers",
        .{server.address().ip4.port},
    );
    defer allocator.free(buffered_trailer_uri);
    var buffered_trailer_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        buffered_trailer_uri,
        .{
            .method = .POST,
            .body = "payload",
            .trailers = &request_trailers,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer buffered_trailer_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        buffered_trailer_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "abc",
        buffered_trailer_response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: trusted forwarded-for overrides the peer address" {
    const allocator = std.testing.allocator;

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
                .trust_forwarded_for = true,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/peer", clientAddressText, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/peer",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    const forwarded_headers = [_]netz.http1.Header{.{
        .name = "X-Forwarded-For",
        .value = "203.0.113.9, 10.0.0.1",
    }};
    var forwarded = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .headers = &forwarded_headers },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer forwarded.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), forwarded.response.status);
    try std.testing.expectEqualStrings(
        "203.0.113.9:0",
        forwarded.response.body,
    );

    var direct = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer direct.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), direct.response.status);
    try std.testing.expect(std.mem.startsWith(
        u8,
        direct.response.body,
        "127.0.0.1:",
    ));

    server.stop();
    try group.await(io);
}

test "package: streaming request bodies reach handlers incrementally" {
    const allocator = std.testing.allocator;

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
                // The multipart case uploads 200 KiB while the request arena
                // stays at 64 KiB, proving the parser streams.
                .max_body_bytes = 512 * 1024,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
                .max_streaming_window_bytes = 32 * 1024,
            },
            .max_connections = 2,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.post("/upload", StreamHandlers.uploadRoute, .{ .streaming = true });
    try router.post(
        "/upload-buffered",
        StreamHandlers.readBodyRoute,
        .{ .streaming = true },
    );
    try router.post(
        "/upload-reject",
        StreamHandlers.rejectUpload,
        .{ .streaming = true },
    );
    try router.post(
        "/upload-limited",
        StreamHandlers.uploadRoute,
        .{ .streaming = true, .max_body_bytes = 4096 },
    );
    try router.post(
        "/upload-limited-buffered",
        StreamHandlers.readBodyRoute,
        .{ .max_body_bytes = 4096 },
    );
    try router.post(
        "/upload-decoded",
        StreamHandlers.decodedUploadRoute,
        .{ .streaming = true },
    );
    try router.post(
        "/upload-multipart-stream",
        StreamHandlers.multipartStreamRoute,
        .{ .streaming = true },
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

    const body = try allocator.alloc(u8, 40 * 1024);
    defer allocator.free(body);
    @memset(body, 'x');

    const upload_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload",
        .{base},
    );
    defer allocator.free(upload_uri);
    var upload_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        upload_uri,
        .{ .method = .POST, .body = body },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer upload_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), upload_response.response.status);
    try std.testing.expectEqualStrings(
        "{\"bytes\":40960}",
        upload_response.response.body,
    );

    const buffered_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload-buffered",
        .{base},
    );
    defer allocator.free(buffered_uri);
    var buffered_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        buffered_uri,
        .{ .method = .POST, .body = body },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer buffered_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), buffered_response.response.status);
    try std.testing.expectEqualStrings(
        "{\"bytes\":40960}",
        buffered_response.response.body,
    );

    const reject_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload-reject",
        .{base},
    );
    defer allocator.free(reject_uri);
    var reject_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        reject_uri,
        .{ .method = .POST, .body = body },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer reject_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 413), reject_response.response.status);
    try std.testing.expectEqualStrings("too large", reject_response.response.body);

    const small_body = try allocator.alloc(u8, 1024);
    defer allocator.free(small_body);
    @memset(small_body, 'y');

    const limited_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload-limited",
        .{base},
    );
    defer allocator.free(limited_uri);
    var limited_ok = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        limited_uri,
        .{ .method = .POST, .body = small_body },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer limited_ok.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), limited_ok.response.status);
    try std.testing.expectEqualStrings(
        "{\"bytes\":1024}",
        limited_ok.response.body,
    );

    var limited_reject = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        limited_uri,
        .{ .method = .POST, .body = body },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer limited_reject.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 413),
        limited_reject.response.status,
    );

    const limited_buffered_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload-limited-buffered",
        .{base},
    );
    defer allocator.free(limited_buffered_uri);
    var limited_buffered_ok = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        limited_buffered_uri,
        .{ .method = .POST, .body = small_body },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer limited_buffered_ok.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        limited_buffered_ok.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"bytes\":1024}",
        limited_buffered_ok.response.body,
    );

    var limited_buffered_reject = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        limited_buffered_uri,
        .{ .method = .POST, .body = body },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer limited_buffered_reject.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 413),
        limited_buffered_reject.response.status,
    );

    const payload = try allocator.alloc(u8, 200 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'q');
    const multipart_body = try std.fmt.allocPrint(
        allocator,
        "--weft\r\n" ++
            "Content-Disposition: form-data; name=\"field\"\r\n" ++
            "\r\n" ++
            "value\r\n" ++
            "--weft\r\n" ++
            "Content-Disposition: form-data; name=\"file\"; " ++
            "filename=\"big.bin\"\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "\r\n" ++
            "{s}\r\n" ++
            "--weft--\r\n",
        .{payload},
    );
    defer allocator.free(multipart_body);

    const multipart_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload-multipart-stream",
        .{base},
    );
    defer allocator.free(multipart_uri);
    const multipart_headers = [_]netz.http1.Header{.{
        .name = "Content-Type",
        .value = "multipart/form-data; boundary=weft",
    }};
    var multipart_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        multipart_uri,
        .{
            .method = .POST,
            .headers = &multipart_headers,
            .body = multipart_body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 512 * 1024 },
    );
    defer multipart_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        multipart_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"field\":\"field\",\"file_bytes\":204800}",
        multipart_response.response.body,
    );

    // A Content-Encoding'd body can be decoded incrementally without
    // buffering the whole upload.
    const decoded_payload = try allocator.alloc(u8, 10 * 1024);
    defer allocator.free(decoded_payload);
    @memset(decoded_payload, 'd');
    const compressed_upload = try gzipAlloc(allocator, decoded_payload);
    defer allocator.free(compressed_upload);
    const decoded_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload-decoded",
        .{base},
    );
    defer allocator.free(decoded_uri);
    const decoded_headers = [_]netz.http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    var decoded_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        decoded_uri,
        .{
            .method = .POST,
            .headers = &decoded_headers,
            .body = compressed_upload,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 512 * 1024 },
    );
    defer decoded_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        decoded_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"bytes\":10240}",
        decoded_response.response.body,
    );

    // A Content-Encoding'd body is decoded incrementally before multipart
    // parsing, so the same handler accepts a gzip-compressed upload.
    const compressed_multipart = try gzipAlloc(allocator, multipart_body);
    defer allocator.free(compressed_multipart);
    const encoded_headers = [_]netz.http1.Header{
        .{
            .name = "Content-Type",
            .value = "multipart/form-data; boundary=weft",
        },
        .{ .name = "Content-Encoding", .value = "gzip" },
    };
    var encoded_multipart = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        multipart_uri,
        .{
            .method = .POST,
            .headers = &encoded_headers,
            .body = compressed_multipart,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 512 * 1024 },
    );
    defer encoded_multipart.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        encoded_multipart.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"field\":\"field\",\"file_bytes\":204800}",
        encoded_multipart.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: streaming decode handles multi-chunk compressed bodies" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    const decodeRoute = struct {
        fn handle(ctx: *weft.Ctx) anyerror!void {
            const reader = if (try ctx.decodedReader()) |decoded|
                weft.BodyReader{ .decoded = decoded }
            else
                ctx.bodyReader().?;
            var total: usize = 0;
            while (try reader.next()) |chunk| total += chunk.len;
            try ctx.json(.{ .bytes = total });
        }
    };

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 128 * 1024,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 4096,
                // Small enough that a 20 KiB upload arrives in many chunks.
                .max_streaming_window_bytes = 4096,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();
    try server.router().addRaw(
        .POST,
        "/decoded",
        weft.handler(decodeRoute.handle),
        .{ .streaming = true },
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const payload = try allocator.alloc(u8, 20 * 1024);
    defer allocator.free(payload);
    var prng = std.Random.DefaultPrng.init(0xdec0_de);
    prng.random().bytes(payload);
    const compressed = try gzipAlloc(allocator, payload);
    defer allocator.free(compressed);

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/decoded",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);
    const headers = [_]netz.http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &headers,
            .body = compressed,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 128 * 1024 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "{\"bytes\":20480}",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: readBody continues an active streaming decoder" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    const mixedRoute = struct {
        fn handle(ctx: *weft.Ctx) anyerror!void {
            const reader = if (try ctx.decodedReader()) |decoded|
                weft.BodyReader{ .decoded = decoded }
            else
                ctx.bodyReader().?;
            var first: usize = 0;
            if (try reader.next()) |chunk| first = chunk.len;
            const rest = try ctx.readBody();
            try ctx.json(.{ .total = first + rest.len });
        }
    };

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 128 * 1024,
                .max_request_arena_bytes = 128 * 1024,
                .max_response_bytes = 4096,
                .max_streaming_window_bytes = 4096,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();
    try server.router().addRaw(
        .POST,
        "/mixed",
        weft.handler(mixedRoute.handle),
        .{ .streaming = true },
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const payload = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(payload);
    var prng = std.Random.DefaultPrng.init(0xbeef_42);
    prng.random().bytes(payload);
    const compressed = try gzipAlloc(allocator, payload);
    defer allocator.free(compressed);

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/mixed",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);
    const headers = [_]netz.http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &headers,
            .body = compressed,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 128 * 1024 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "{\"total\":16384}",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: streaming byte budget failure becomes 500" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 128,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/stream/oversized", StreamHandlers.oversizedRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/stream/oversized",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 500), response.response.status);

    server.stop();
    try group.await(io);
}

test "package: static files serve 200, 304, 206, and HEAD" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "index.html",
        .data = "<h1>static</h1>",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "app.js",
        .data = "console.log('static');",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".env",
        .data = "SECRET=1",
    });

    var static = weft.StaticFiles{ .dir = tmp.dir, .download = true };

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const runtime_io = backend.io();

    var server = try weft.Server(App).init(
        runtime_io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 2,
        },
        .{},
    );
    defer server.deinit();

    try server.router().addRaw(
        .GET,
        "/assets/*",
        static.handler(),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(runtime_io);
    try group.concurrent(runtime_io, serveServer, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/assets",
        .{server.address().ip4.port},
    );
    defer allocator.free(base);

    var directory_redirect = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        base,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer directory_redirect.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 301),
        directory_redirect.response.status,
    );
    try std.testing.expectEqualStrings(
        "/assets/",
        directory_redirect.response.header("location").?,
    );

    const directory_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/",
        .{base},
    );
    defer allocator.free(directory_uri);
    var directory_index = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        directory_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer directory_index.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        directory_index.response.status,
    );
    try std.testing.expectEqualStrings(
        "<h1>static</h1>",
        directory_index.response.body,
    );

    const index_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/index.html",
        .{base},
    );
    defer allocator.free(index_uri);

    var index_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer index_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), index_response.response.status);
    try std.testing.expectEqualStrings(
        "<h1>static</h1>",
        index_response.response.body,
    );
    try std.testing.expectEqualStrings(
        "text/html; charset=utf-8",
        index_response.response.header("content-type").?,
    );
    try std.testing.expectEqualStrings(
        "attachment; filename=\"index.html\"",
        index_response.response.header("content-disposition").?,
    );
    const etag = index_response.response.header("etag").?;
    const last_modified = index_response.response.header("last-modified").?;

    var modified_since = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{.{
            .name = "If-Modified-Since",
            .value = last_modified,
        }} },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer modified_since.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 304), modified_since.response.status);
    try std.testing.expectEqualStrings(
        last_modified,
        modified_since.response.header("last-modified").?,
    );

    var stale_modified_since = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{.{
            .name = "If-Modified-Since",
            .value = "Thu, 01 Jan 1970 00:00:00 GMT",
        }} },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer stale_modified_since.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        stale_modified_since.response.status,
    );

    var failed_if_match = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{.{
            .name = "If-Match",
            .value = "\"different\"",
        }} },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer failed_if_match.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 412), failed_if_match.response.status);

    var failed_unmodified_since = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{.{
            .name = "If-Unmodified-Since",
            .value = "Thu, 01 Jan 1970 00:00:00 GMT",
        }} },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer failed_unmodified_since.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 412),
        failed_unmodified_since.response.status,
    );

    var conditional_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{.{
            .name = "If-None-Match",
            .value = etag,
        }} },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer conditional_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 304),
        conditional_response.response.status,
    );
    try std.testing.expectEqualStrings("", conditional_response.response.body);

    var range_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{.{
            .name = "Range",
            .value = "bytes=0-3",
        }} },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer range_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 206), range_response.response.status);
    try std.testing.expectEqualStrings(
        "<h1>",
        range_response.response.body,
    );
    try std.testing.expectEqualStrings(
        "bytes 0-3/15",
        range_response.response.header("content-range").?,
    );

    var stale_range = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{
            .{ .name = "Range", .value = "bytes=0-3" },
            .{ .name = "If-Range", .value = "\"different\"" },
        } },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer stale_range.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), stale_range.response.status);
    try std.testing.expectEqualStrings(
        "<h1>static</h1>",
        stale_range.response.body,
    );
    try std.testing.expect(stale_range.response.header("content-range") == null);

    var dated_range = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{
            .{ .name = "Range", .value = "bytes=0-3" },
            .{ .name = "If-Range", .value = last_modified },
        } },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer dated_range.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 206), dated_range.response.status);
    try std.testing.expectEqualStrings("<h1>", dated_range.response.body);

    var stale_dated_range = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{
            .{ .name = "Range", .value = "bytes=0-3" },
            .{ .name = "If-Range", .value = "Thu, 01 Jan 1970 00:00:00 GMT" },
        } },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer stale_dated_range.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), stale_dated_range.response.status);
    try std.testing.expectEqualStrings("<h1>static</h1>", stale_dated_range.response.body);
    try std.testing.expect(
        stale_dated_range.response.header("content-range") == null,
    );

    var multi_range = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .headers = &.{.{
            .name = "Range",
            .value = "bytes=0-1,4-5",
        }} },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer multi_range.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 206), multi_range.response.status);
    const multipart_type = multi_range.response.header("content-type").?;
    try std.testing.expect(std.mem.startsWith(
        u8,
        multipart_type,
        "multipart/byteranges; boundary=",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        multi_range.response.body,
        "Content-Range: bytes 0-1/15",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        multi_range.response.body,
        "Content-Range: bytes 4-5/15",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        multi_range.response.body,
        "<h",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        multi_range.response.body,
        "st",
    ) != null);

    var head_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        index_uri,
        .{ .method = .HEAD },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer head_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), head_response.response.status);
    try std.testing.expectEqualStrings("", head_response.response.body);
    try std.testing.expectEqualStrings(
        "15",
        head_response.response.header("content-length").?,
    );
    try std.testing.expectEqualStrings(
        "attachment; filename=\"index.html\"",
        head_response.response.header("content-disposition").?,
    );

    const js_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/app.js",
        .{base},
    );
    defer allocator.free(js_uri);
    var js_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        js_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer js_response.deinit(allocator);
    try std.testing.expectEqualStrings(
        "text/javascript; charset=utf-8",
        js_response.response.header("content-type").?,
    );

    const missing_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/missing.txt",
        .{base},
    );
    defer allocator.free(missing_uri);
    var missing_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        missing_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer missing_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), missing_response.response.status);

    const hidden_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/.env",
        .{base},
    );
    defer allocator.free(hidden_uri);
    var hidden_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        hidden_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer hidden_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), hidden_response.response.status);
    try std.testing.expectEqualStrings("Not Found", hidden_response.response.body);

    server.stop();
    try group.await(runtime_io);
}

test "package: static files negotiate precompressed sidecars" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const raw_body = "<h1>compressed static</h1>";
    const compressed = try gzipAlloc(allocator, raw_body);
    defer allocator.free(compressed);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "index.html",
        .data = raw_body,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "index.html.gz",
        .data = compressed,
    });

    var static = weft.StaticFiles{ .dir = tmp.dir, .download = true };

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const runtime_io = backend.io();

    var server = try weft.Server(App).init(
        runtime_io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 2,
        },
        .{},
    );
    defer server.deinit();

    try server.router().addRaw(.GET, "/assets/*", static.handler(), .{});

    var group: std.Io.Group = .init;
    defer group.cancel(runtime_io);
    try group.concurrent(runtime_io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/assets/index.html",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var encoded = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        uri,
        .{ .headers = &.{.{
            .name = "Accept-Encoding",
            .value = "gzip",
        }} },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer encoded.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), encoded.response.status);
    try std.testing.expectEqualStrings(
        "gzip",
        encoded.response.header("content-encoding").?,
    );
    try std.testing.expectEqualStrings(
        "text/html; charset=utf-8",
        encoded.response.header("content-type").?,
    );
    try std.testing.expectEqualStrings(
        "Accept-Encoding",
        encoded.response.header("vary").?,
    );
    try std.testing.expect(encoded.response.header("accept-ranges") == null);
    try std.testing.expectEqualStrings(compressed, encoded.response.body);

    var identity = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer identity.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), identity.response.status);
    try std.testing.expect(identity.response.header("content-encoding") == null);
    try std.testing.expectEqualStrings("bytes", identity.response.header(
        "accept-ranges",
    ).?);
    try std.testing.expectEqualStrings(raw_body, identity.response.body);

    // Unknown codings fall back to the raw representation.
    var unknown = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        uri,
        .{ .headers = &.{.{
            .name = "Accept-Encoding",
            .value = "br",
        }} },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer unknown.deinit(allocator);
    try std.testing.expect(unknown.response.header("content-encoding") == null);
    try std.testing.expectEqualStrings(raw_body, unknown.response.body);

    // Range requests bypass encoded representations so byte offsets stay valid.
    var ranged = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        uri,
        .{ .headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
            .{ .name = "Range", .value = "bytes=0-3" },
        } },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer ranged.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 206), ranged.response.status);
    try std.testing.expect(ranged.response.header("content-encoding") == null);
    try std.testing.expectEqualStrings("<h1>", ranged.response.body);

    // HEAD reports the encoded length without sending a body.
    var head = try netz.http1.runtime.Client.requestUri(
        allocator,
        runtime_io,
        uri,
        .{
            .method = .HEAD,
            .headers = &.{.{
                .name = "Accept-Encoding",
                .value = "gzip",
            }},
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer head.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), head.response.status);
    try std.testing.expectEqualStrings("", head.response.body);
    const encoded_length = try std.fmt.allocPrint(
        allocator,
        "{d}",
        .{compressed.len},
    );
    defer allocator.free(encoded_length);
    try std.testing.expectEqualStrings(
        encoded_length,
        head.response.header("content-length").?,
    );

    server.stop();
    try group.await(runtime_io);
}

test "package: gzip request bodies are decoded for JSON handlers" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().post("/echo", echoJson, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const compressed = try gzipAlloc(
        allocator,
        "{\"message\":\"weft\"}",
    );
    defer allocator.free(compressed);

    var headers = [_]netz.http1.Header{
        .{ .name = "Content-Encoding", .value = "gzip" },
        .{ .name = "Content-Type", .value = "application/json" },
    };

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/echo",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &headers,
            .body = compressed,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "{\"message\":\"weft\"}",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: invalid JSON and unsupported encodings map to 400 and 415" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 2,
        },
        .{},
    );
    defer server.deinit();

    try server.router().post("/echo", echoJson, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/echo",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var invalid_json = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .body = "{",
            .headers = &.{.{
                .name = "Content-Type",
                .value = "application/json",
            }},
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer invalid_json.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 400), invalid_json.response.status);

    var unsupported = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .body = "{}",
            .headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Content-Encoding", .value = "compress" },
            },
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer unsupported.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 415), unsupported.response.status);

    var wrong_type = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .body = "{}",
            .headers = &.{.{
                .name = "Content-Type",
                .value = "text/plain",
            }},
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer wrong_type.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 415), wrong_type.response.status);

    var problem_json = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .body = "{\"message\":\"weft\"}",
            .headers = &.{.{
                .name = "Content-Type",
                .value = "application/problem+json; charset=utf-8",
            }},
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer problem_json.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), problem_json.response.status);
    try std.testing.expectEqualStrings(
        "{\"message\":\"weft\"}",
        problem_json.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: TLS server serves HTTPS requests" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var certificate_der: [netz.tls.testing.certificate_der_len]u8 = undefined;
    try std.base64.standard.Decoder.decode(
        &certificate_der,
        netz.tls.testing.certificate_base64,
    );
    const key_pair = try netz.tls.testing.serverKeyPair();

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
            .tls = .{
                .identity = .{
                    .certificate_chain = &.{&certificate_der},
                    .signer = .{ .ecdsa_p256_sha256 = .{
                        .key_pair = key_pair,
                    } },
                },
            },
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "https://127.0.0.1:{d}/",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUriTls(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
        .{ .verify_host = false },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "hello from weft",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: mutual TLS exposes the client certificate chain" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var certificate_der: [netz.tls.testing.certificate_der_len]u8 = undefined;
    try std.base64.standard.Decoder.decode(
        &certificate_der,
        netz.tls.testing.certificate_base64,
    );
    const key_pair = try netz.tls.testing.serverKeyPair();
    const public_key = key_pair.public_key.toUncompressedSec1();

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
            .tls = .{
                .identity = .{
                    .certificate_chain = &.{&certificate_der},
                    .signer = .{ .ecdsa_p256_sha256 = .{
                        .key_pair = key_pair,
                    } },
                },
                .client_auth = .{ .verifier = .{
                    .pinned_ecdsa_p256_public_key = public_key,
                } },
                .alpn_protocols = &.{"http/1.1"},
                .cipher_suites = &.{.aes_256_gcm_sha384},
            },
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/certs", certificateCount, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    var client = try netz.http1.runtime.Client.connectVailTlsHost(
        allocator,
        io,
        "localhost",
        server.address().ip4.port,
        .{},
        .{
            .server_verifier = .{
                .pinned_ecdsa_p256_public_key = public_key,
            },
            .client_identity = .{
                .certificate_chain = &.{&certificate_der},
                .signer = .{ .ecdsa_p256_sha256 = .{
                    .key_pair = key_pair,
                } },
            },
            .alpn_protocols = &.{"http/1.1"},
            .cipher_suites = &.{.aes_256_gcm_sha384},
        },
    );
    defer client.close();

    var response = try client.request(.{
        .method = .GET,
        .target = "/certs",
        .host = "localhost",
    });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "{\"certs\":1}",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: request timeout cancels slow handlers and allows fast ones" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
                .request_timeout = .fromMilliseconds(50),
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/slow", slowHandler, .{});
    try router.get("/fast", home, .{});
    try router.get("/deadline", deadlineInfo, .{});
    try router.get(
        "/slow-route-timeout",
        slowHandler,
        .{ .timeout = .fromMilliseconds(500) },
    );
    try router.get(
        "/slow-no-timeout",
        slowHandler,
        .{ .timeout = .fromSeconds(30) },
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const slow_uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/slow",
        .{server.address().ip4.port},
    );
    defer allocator.free(slow_uri);

    var slow_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        slow_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer slow_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 503), slow_response.response.status);

    const fast_uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/fast",
        .{server.address().ip4.port},
    );
    defer allocator.free(fast_uri);

    var fast_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        fast_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer fast_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), fast_response.response.status);
    try std.testing.expectEqualStrings(
        "hello from weft",
        fast_response.response.body,
    );

    const deadline_uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/deadline",
        .{server.address().ip4.port},
    );
    defer allocator.free(deadline_uri);
    const route_timeout_uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/slow-route-timeout",
        .{server.address().ip4.port},
    );
    defer allocator.free(route_timeout_uri);
    var route_timeout_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        route_timeout_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer route_timeout_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        route_timeout_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "slow",
        route_timeout_response.response.body,
    );

    const route_timeout_uri2 = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/slow-no-timeout",
        .{server.address().ip4.port},
    );
    defer allocator.free(route_timeout_uri2);
    var route_timeout_response2 = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        route_timeout_uri2,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer route_timeout_response2.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        route_timeout_response2.response.status,
    );

    var deadline_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        deadline_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer deadline_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        deadline_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"has_deadline\":true,\"expired\":false}",
        deadline_response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: HTTP/2 adapter serves routes, errors, and streams" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
                .max_http2_concurrent_streams = 32,
            },
            .max_connections = 2,
            .max_concurrent_handlers = 32,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(100),
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/hello/:name", hello, .{});
    try router.get("/info", clientInfo, .{});
    try router.post("/echo", echoJson, .{});
    try router.post("/body-echo", echoBufferedBody, .{});
    try router.post(
        "/upload",
        StreamHandlers.uploadRoute,
        .{ .streaming = true },
    );
    try router.post(
        "/streaming-probe",
        StreamHandlers.streamingProbeRoute,
        .{ .streaming = true },
    );
    try router.get("/trailers", trailerRoute, .{});
    try router.get("/trailers-stream", streamingTrailerRoute, .{});
    try router.post(
        "/upload-trailers",
        streamingTrailerEcho,
        .{ .streaming = true },
    );
    try router.post(
        "/upload-multipart-stream",
        StreamHandlers.multipartStreamRoute,
        .{ .streaming = true },
    );
    try router.get("/stream/fixed", StreamHandlers.fixedRoute, .{});
    try router.get("/cookies", cookiesRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{server.address().ip4.port},
    );
    defer allocator.free(base);

    const hello_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/hello/weft?lang=zh",
        .{base},
    );
    defer allocator.free(hello_uri);
    var hello_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        hello_uri,
        .{},
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer hello_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), hello_response.status);
    try std.testing.expectEqualStrings(
        "{\"message\":\"hello\",\"name\":\"weft\"}",
        hello_response.body,
    );

    // A buffered HEAD response preserves the representation length even
    // though no DATA is sent.
    var hello_head = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        hello_uri,
        .{ .method = "HEAD" },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer hello_head.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), hello_head.status);
    try std.testing.expectEqualStrings("", hello_head.body);
    const hello_length = try std.fmt.allocPrint(
        allocator,
        "{d}",
        .{hello_response.body.len},
    );
    defer allocator.free(hello_length);
    try std.testing.expectEqualStrings(
        hello_length,
        h2Header(&hello_head, "content-length").?,
    );

    const info_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/info",
        .{base},
    );
    defer allocator.free(info_uri);
    var info_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        info_uri,
        .{},
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer info_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), info_response.status);
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"http_2\",\"has_address\":true,\"tls\":false}",
        info_response.body,
    );

    const missing_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/missing",
        .{base},
    );
    defer allocator.free(missing_uri);
    var missing_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        missing_uri,
        .{},
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer missing_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), missing_response.status);
    try std.testing.expectEqualStrings("Not Found", missing_response.body);

    const echo_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/echo",
        .{base},
    );
    defer allocator.free(echo_uri);
    var echo_headers = [_]netz.http2.Hpack.HeaderField{.{
        .name = "content-type",
        .value = "application/json",
    }};
    var echo_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        echo_uri,
        .{
            .method = "POST",
            .body = "{\"message\":\"weft\"}",
            .headers = &echo_headers,
        },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer echo_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), echo_response.status);
    try std.testing.expectEqualStrings(
        "{\"message\":\"weft\"}",
        echo_response.body,
    );

    // Non-streaming routes expose the buffered request through Ctx.body().
    const body_echo_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/body-echo",
        .{base},
    );
    defer allocator.free(body_echo_uri);
    var body_echo_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        body_echo_uri,
        .{
            .method = "POST",
            .body = "buffered request body",
        },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer body_echo_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), body_echo_response.status);
    try std.testing.expectEqualStrings(
        "buffered request body",
        body_echo_response.body,
    );

    const upload_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/upload",
        .{base},
    );
    defer allocator.free(upload_uri);
    const upload_body = try allocator.alloc(u8, 2048);
    defer allocator.free(upload_body);
    @memset(upload_body, 'x');
    var upload_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        upload_uri,
        .{
            .method = "POST",
            .body = upload_body,
        },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer upload_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), upload_response.status);
    try std.testing.expectEqualStrings(
        "{\"bytes\":2048}",
        upload_response.body,
    );

    // Streaming-route detection must use the path, not the whole target, so
    // a query string does not silently turn the route into a buffered one.
    const probe_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/streaming-probe?check=1",
        .{base},
    );
    defer allocator.free(probe_uri);
    var probe_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        probe_uri,
        .{
            .method = "POST",
            .body = "probe",
        },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer probe_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), probe_response.status);
    try std.testing.expectEqualStrings(
        "{\"streaming\":true}",
        probe_response.body,
    );

    const trailers_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/trailers",
        .{base},
    );
    defer allocator.free(trailers_uri);
    const te_header = [_]netz.http2.Hpack.HeaderField{.{
        .name = "te",
        .value = "trailers",
    }};
    var trailers_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        trailers_uri,
        .{ .headers = &te_header },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer trailers_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), trailers_response.status);
    try std.testing.expectEqualStrings("body", trailers_response.body);
    try std.testing.expectEqual(@as(usize, 1), trailers_response.trailers.len);
    try std.testing.expectEqualStrings("abc", trailers_response.trailers[0].value);

    const trailers_stream_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/trailers-stream",
        .{base},
    );
    defer allocator.free(trailers_stream_uri);
    var trailers_stream_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        trailers_stream_uri,
        .{ .headers = &te_header },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer trailers_stream_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        trailers_stream_response.status,
    );
    try std.testing.expectEqualStrings("body", trailers_stream_response.body);
    try std.testing.expectEqual(
        @as(usize, 1),
        trailers_stream_response.trailers.len,
    );
    try std.testing.expectEqualStrings(
        "abc",
        trailers_stream_response.trailers[0].value,
    );

    var batch_client = try netz.http2.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer batch_client.close();
    var batch_requests: [32]netz.http2.runtime.RequestOptions = undefined;
    for (&batch_requests, 0..) |*request, index| {
        request.* = .{
            .path = if (index % 2 == 0) "/hello/one" else "/hello/two",
            .authority = "localhost",
        };
    }
    var batch_responses: [32]netz.http2.runtime.OwnedResponse = undefined;
    try batch_client.requestBatchInto(&batch_requests, &batch_responses);
    defer for (&batch_responses) |*response| response.deinit(allocator);
    for (&batch_responses, 0..) |*response, index| {
        try std.testing.expectEqual(@as(u16, 200), response.status);
        const expected = if (index % 2 == 0) "one" else "two";
        try std.testing.expect(std.mem.indexOf(
            u8,
            response.body,
            expected,
        ) != null);
    }

    var upload_batch_requests: [32]netz.http2.runtime.RequestOptions = undefined;
    for (&upload_batch_requests) |*request| {
        request.* = .{
            .method = "POST",
            .path = "/upload",
            .authority = "localhost",
            .body = upload_body,
        };
    }
    var upload_batch_responses: [32]netz.http2.runtime.OwnedResponse = undefined;
    try batch_client.requestBodyBatchInto(
        &upload_batch_requests,
        4096,
        &upload_batch_responses,
    );
    defer for (&upload_batch_responses) |*response| response.deinit(allocator);
    for (&upload_batch_responses) |*response| {
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expectEqualStrings(
            "{\"bytes\":2048}",
            response.body,
        );
    }

    const upload_trailer_headers = [_]netz.http2.Hpack.HeaderField{.{
        .name = "x-checksum",
        .value = "abc",
    }};
    var upload_trailer_response = try batch_client.request(.{
        .method = "POST",
        .path = "/upload-trailers",
        .authority = "localhost",
        .body = "payload",
        .trailers = &upload_trailer_headers,
    });
    defer upload_trailer_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        upload_trailer_response.status,
    );
    try std.testing.expectEqualStrings(
        "abc",
        upload_trailer_response.body,
    );

    const h2_file = try allocator.alloc(u8, 1024);
    defer allocator.free(h2_file);
    @memset(h2_file, 'h');
    const h2_multipart_body = try std.fmt.allocPrint(
        allocator,
        "--weft\r\n" ++
            "Content-Disposition: form-data; name=\"field\"\r\n" ++
            "\r\n" ++
            "value\r\n" ++
            "--weft\r\n" ++
            "Content-Disposition: form-data; name=\"file\"; " ++
            "filename=\"h2.bin\"\r\n" ++
            "\r\n" ++
            "{s}\r\n" ++
            "--weft--\r\n",
        .{h2_file},
    );
    defer allocator.free(h2_multipart_body);
    var h2_multipart_headers = [_]netz.http2.Hpack.HeaderField{.{
        .name = "content-type",
        .value = "multipart/form-data; boundary=weft",
    }};
    var h2_multipart_response = try batch_client.request(.{
        .method = "POST",
        .path = "/upload-multipart-stream",
        .authority = "localhost",
        .headers = &h2_multipart_headers,
        .body = h2_multipart_body,
    });
    defer h2_multipart_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        h2_multipart_response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"field\":\"field\",\"file_bytes\":1024}",
        h2_multipart_response.body,
    );

    var h2_cookies = try batch_client.request(.{
        .method = "GET",
        .path = "/cookies",
        .authority = "localhost",
    });
    defer h2_cookies.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), h2_cookies.status);
    var h2_cookie_count: usize = 0;
    for (h2_cookies.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) {
            h2_cookie_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), h2_cookie_count);

    const stream_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/stream/fixed",
        .{base},
    );
    defer allocator.free(stream_uri);
    var stream_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        stream_uri,
        .{},
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer stream_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), stream_response.status);
    try std.testing.expectEqualStrings("hello stream", stream_response.body);

    var head_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        stream_uri,
        .{ .method = "HEAD" },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer head_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), head_response.status);
    try std.testing.expectEqualStrings("", head_response.body);
    try std.testing.expectEqualStrings(
        "12",
        h2Header(&head_response, "content-length").?,
    );

    server.stop();
    try group.await(io);
}

test "package: HTTP/3 adapter serves routes, POST, and streams" {
    const allocator = std.testing.allocator;

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
                .max_request_target_bytes = 32,
                .max_body_bytes = 512 * 1024,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
                .max_streaming_window_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .max_concurrent_streams = 32,
            .max_concurrent_handlers = 32,
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

    var router = server.router();
    try router.get("/hello/:name", hello, .{});
    try router.get("/info", clientInfo, .{});
    try router.post("/echo", echoJson, .{});
    try router.get("/stream/fixed", StreamHandlers.fixedRoute, .{});
    try router.get("/trailers", trailerRoute, .{});
    try router.post(
        "/upload",
        StreamHandlers.uploadRoute,
        .{ .streaming = true },
    );
    try router.post(
        "/streaming-probe",
        StreamHandlers.streamingProbeRoute,
        .{ .streaming = true },
    );
    try router.get("/trailers-stream", streamingTrailerRoute, .{});
    try router.post(
        "/upload-multipart-stream",
        StreamHandlers.multipartStreamRoute,
        .{ .streaming = true },
    );
    try router.get("/cookies", cookiesRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp3Server, .{&server});

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

    var hello_response = try client.request(.{
        .method = "GET",
        .path = "/hello/weft?lang=zh",
        .authority = "localhost",
    });
    defer hello_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        hello_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"message\":\"hello\",\"name\":\"weft\"}",
        hello_response.response.body,
    );

    var hello_head = try client.request(.{
        .method = "HEAD",
        .path = "/hello/weft?lang=zh",
        .authority = "localhost",
    });
    defer hello_head.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        hello_head.response.status,
    );
    try std.testing.expectEqualStrings("", hello_head.response.body);
    const hello_length = try std.fmt.allocPrint(
        allocator,
        "{d}",
        .{hello_response.response.body.len},
    );
    defer allocator.free(hello_length);
    try std.testing.expectEqualStrings(
        hello_length,
        h3Header(&hello_head, "content-length").?,
    );

    // HTTP/3 must apply the same request-target budget as HTTP/1.
    var long_path: [64]u8 = undefined;
    @memset(&long_path, 'a');
    long_path[0] = '/';
    var long_target_response = try client.request(.{
        .method = "GET",
        .path = &long_path,
        .authority = "localhost",
    });
    defer long_target_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 414),
        long_target_response.response.status,
    );

    var connect_response = try client.request(.{
        .method = "CONNECT",
        .path = "",
        .authority = "example.com:443",
    });
    defer connect_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 501),
        connect_response.response.status,
    );

    const upload_body = try allocator.alloc(u8, 2048);
    defer allocator.free(upload_body);
    @memset(upload_body, 'x');
    var upload_response = try client.request(.{
        .method = "POST",
        .path = "/upload",
        .authority = "localhost",
        .body = upload_body,
    });
    defer upload_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        upload_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"bytes\":2048}",
        upload_response.response.body,
    );

    // Streaming-route detection must ignore the query string on HTTP/3 too.
    var h3_probe_response = try client.request(.{
        .method = "POST",
        .path = "/streaming-probe?check=1",
        .authority = "localhost",
        .body = "probe",
    });
    defer h3_probe_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        h3_probe_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"streaming\":true}",
        h3_probe_response.response.body,
    );

    // Exceed the per-stream resident window so the owner must pause and
    // resume reading while the handler drains the bounded queue.
    const large_upload = try allocator.alloc(u8, 400 * 1024);
    defer allocator.free(large_upload);
    @memset(large_upload, 'y');
    var large_upload_response = try client.request(.{
        .method = "POST",
        .path = "/upload",
        .authority = "localhost",
        .body = large_upload,
    });
    defer large_upload_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        large_upload_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"bytes\":409600}",
        large_upload_response.response.body,
    );

    const h3_file = try allocator.alloc(u8, 300 * 1024);
    defer allocator.free(h3_file);
    @memset(h3_file, 'm');
    const h3_multipart_body = try std.fmt.allocPrint(
        allocator,
        "--weft\r\n" ++
            "Content-Disposition: form-data; name=\"field\"\r\n" ++
            "\r\n" ++
            "value\r\n" ++
            "--weft\r\n" ++
            "Content-Disposition: form-data; name=\"file\"; " ++
            "filename=\"h3.bin\"\r\n" ++
            "\r\n" ++
            "{s}\r\n" ++
            "--weft--\r\n",
        .{h3_file},
    );
    defer allocator.free(h3_multipart_body);
    var h3_multipart_headers = [_]netz.http3.Qpack.HeaderField{.{
        .name = "content-type",
        .value = "multipart/form-data; boundary=weft",
    }};
    var h3_multipart_response = try client.request(.{
        .method = "POST",
        .path = "/upload-multipart-stream",
        .authority = "localhost",
        .headers = &h3_multipart_headers,
        .body = h3_multipart_body,
    });
    defer h3_multipart_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        h3_multipart_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"field\":\"field\",\"file_bytes\":307200}",
        h3_multipart_response.response.body,
    );

    var h3_cookies = try client.request(.{
        .method = "GET",
        .path = "/cookies",
        .authority = "localhost",
    });
    defer h3_cookies.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), h3_cookies.response.status);
    var h3_cookie_count: usize = 0;
    for (h3_cookies.response.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) {
            h3_cookie_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), h3_cookie_count);

    var trailer_response = try client.request(.{
        .method = "GET",
        .path = "/trailers",
        .authority = "localhost",
    });
    defer trailer_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        trailer_response.response.status,
    );
    try std.testing.expectEqualStrings("body", trailer_response.response.body);
    try std.testing.expectEqual(
        @as(usize, 1),
        trailer_response.response.trailers.len,
    );
    try std.testing.expectEqualStrings(
        "abc",
        trailer_response.response.trailers[0].value,
    );

    var trailer_stream_response = try client.request(.{
        .method = "GET",
        .path = "/trailers-stream",
        .authority = "localhost",
    });
    defer trailer_stream_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        trailer_stream_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "body",
        trailer_stream_response.response.body,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        trailer_stream_response.response.trailers.len,
    );
    try std.testing.expectEqualStrings(
        "abc",
        trailer_stream_response.response.trailers[0].value,
    );

    const BatchCtx = struct {
        allocator: std.mem.Allocator,
        expected_body: ?[]const u8 = null,
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
                    if (self.expected_body) |expected| {
                        if (!std.mem.eql(
                            u8,
                            response.response.body,
                            expected,
                        )) {
                            self.ok = false;
                        }
                    }
                },
                .err => self.ok = false,
            }
        }
    };
    var batch_context = BatchCtx{ .allocator = allocator };
    var batch_requests: [32]netz.http3.Request = undefined;
    for (&batch_requests, 0..) |*request, index| {
        request.* = .{
            .method = "GET",
            .path = if (index % 2 == 0) "/hello/one" else "/hello/two",
            .authority = "localhost",
        };
    }
    var batch_deadlines: [32]?std.Io.Clock.Timestamp = undefined;
    for (&batch_deadlines) |*deadline| deadline.* = null;
    try client.requestBatchWithPerStreamDeadlines(
        &batch_requests,
        &batch_deadlines,
        .{
            .context = &batch_context,
            .on_result = BatchCtx.onResult,
        },
    );
    try std.testing.expectEqual(@as(usize, 32), batch_context.count);
    try std.testing.expect(batch_context.ok);

    var upload_batch_context = BatchCtx{
        .allocator = allocator,
        .expected_body = "{\"bytes\":2048}",
    };
    var upload_batch_requests: [32]netz.http3.Request = undefined;
    for (&upload_batch_requests) |*request| {
        request.* = .{
            .method = "POST",
            .path = "/upload",
            .authority = "localhost",
            .body = upload_body,
        };
    }
    var upload_batch_deadlines: [32]?std.Io.Clock.Timestamp = undefined;
    for (&upload_batch_deadlines) |*deadline| deadline.* = null;
    try client.requestBatchWithPerStreamDeadlines(
        &upload_batch_requests,
        &upload_batch_deadlines,
        .{
            .context = &upload_batch_context,
            .on_result = BatchCtx.onResult,
        },
    );
    try std.testing.expectEqual(@as(usize, 32), upload_batch_context.count);
    try std.testing.expect(upload_batch_context.ok);

    var info_response = try client.request(.{
        .method = "GET",
        .path = "/info",
        .authority = "localhost",
    });
    defer info_response.deinit(allocator);
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"http_3\",\"has_address\":true,\"tls\":true}",
        info_response.response.body,
    );

    var echo_headers = [_]netz.http3.Qpack.HeaderField{.{
        .name = "content-type",
        .value = "application/json",
    }};
    var echo_response = try client.request(.{
        .method = "POST",
        .path = "/echo",
        .authority = "localhost",
        .headers = &echo_headers,
        .body = "{\"message\":\"weft\"}",
    });
    defer echo_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        echo_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "{\"message\":\"weft\"}",
        echo_response.response.body,
    );

    var stream_response = try client.request(.{
        .method = "GET",
        .path = "/stream/fixed",
        .authority = "localhost",
    });
    defer stream_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        stream_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "hello stream",
        stream_response.response.body,
    );

    var head_response = try client.request(.{
        .method = "HEAD",
        .path = "/stream/fixed",
        .authority = "localhost",
    });
    defer head_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        head_response.response.status,
    );
    try std.testing.expectEqualStrings("", head_response.response.body);
    try std.testing.expectEqualStrings(
        "12",
        h3Header(&head_response, "content-length").?,
    );

    server.stop();
    try group.await(io);
}

test "package: HTTP/3 TLS serves HTTPS with real identity" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var certificate_der: [netz.tls.testing.certificate_der_len]u8 = undefined;
    try std.base64.standard.Decoder.decode(
        &certificate_der,
        netz.tls.testing.certificate_base64,
    );
    const key_pair = try netz.tls.testing.serverKeyPair();
    const public_key = key_pair.public_key.toUncompressedSec1();

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
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .accept_timeout = .fromMilliseconds(500),
            .idle_timeout = .fromMilliseconds(100),
            .quic_limits = .{
                .max_datagram_size = 4096,
                .max_frames_per_datagram = 8,
            },
            .handshake = .{
                .local_connection_id = &server_cid,
                .identity = .{
                    .certificate_chain = &.{&certificate_der},
                    .signer = .{ .ecdsa_p256_sha256 = .{
                        .key_pair = key_pair,
                    } },
                },
            },
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp3Server, .{&server});

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
                .server_auth = .{
                    .pinned_ecdsa_p256_public_key = public_key,
                },
            },
        },
    );
    defer client.deinit();

    var response = try client.request(.{
        .method = "GET",
        .path = "/",
        .authority = "localhost",
    });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings("hello from weft", response.response.body);

    server.stop();
    try group.await(io);
}

test "package: HTTP/2 TLS serves HTTPS with ALPN h2" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var certificate_der: [netz.tls.testing.certificate_der_len]u8 = undefined;
    try std.base64.standard.Decoder.decode(
        &certificate_der,
        netz.tls.testing.certificate_base64,
    );
    const key_pair = try netz.tls.testing.serverKeyPair();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pem = try std.fmt.allocPrint(
        allocator,
        "-----BEGIN CERTIFICATE-----\n{s}\n-----END CERTIFICATE-----\n",
        .{netz.tls.testing.certificate_base64},
    );
    defer allocator.free(pem);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cert.pem",
        .data = pem,
    });

    var ca_bundle = std.crypto.Certificate.Bundle.empty;
    defer ca_bundle.deinit(allocator);
    try ca_bundle.addCertsFromFilePath(
        allocator,
        std.testing.io,
        std.Io.Clock.real.now(std.testing.io),
        tmp.dir,
        "cert.pem",
    );
    var ca_lock = std.Io.RwLock.init;

    var server = try weft.Http2Server(App).init(
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
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(100),
            .tls_accept_timeout = .fromMilliseconds(500),
            .tls = .{
                .identity = .{
                    .certificate_chain = &.{&certificate_der},
                    .signer = .{ .ecdsa_p256_sha256 = .{
                        .key_pair = key_pair,
                    } },
                },
            },
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/", home, .{});
    try router.get("/info", clientInfo, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "https://127.0.0.1:{d}/",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http2.runtime.Client.requestUriTls(
        allocator,
        io,
        uri,
        .{},
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
        .{
            .verify_host = false,
            .ca_bundle = .{
                .bundle = &ca_bundle,
                .lock = &ca_lock,
            },
        },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("hello from weft", response.body);

    const info_uri = try std.fmt.allocPrint(
        allocator,
        "https://127.0.0.1:{d}/info",
        .{server.address().ip4.port},
    );
    defer allocator.free(info_uri);
    var info_response = try netz.http2.runtime.Client.requestUriTls(
        allocator,
        io,
        info_uri,
        .{},
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
        .{
            .verify_host = false,
            .ca_bundle = .{
                .bundle = &ca_bundle,
                .lock = &ca_lock,
            },
        },
    );
    defer info_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), info_response.status);
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"http_2\",\"has_address\":true,\"tls\":true}",
        info_response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: multipart upload parsing" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().post("/upload", upload, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const body =
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"field\"\r\n" ++
        "\r\n" ++
        "value\r\n" ++
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "hello\r\n" ++
        "--weft--\r\n";
    var headers = [_]netz.http1.Header{.{
        .name = "Content-Type",
        .value = "multipart/form-data; boundary=weft",
    }};

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/upload",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &headers,
            .body = body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "{\"field\":\"value\",\"filename\":\"a.txt\",\"size\":5}",
        response.response.body,
    );

    var missing_boundary_headers = [_]netz.http1.Header{.{
        .name = "Content-Type",
        .value = "multipart/form-data",
    }};
    var missing_boundary = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &missing_boundary_headers,
            .body = "body",
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer missing_boundary.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 400), missing_boundary.response.status);

    server.stop();
    try group.await(io);
}

test "package: OPTIONS star advertises router methods" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/", home, .{});
    try router.post("/echo", echoJson, .{});

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

    var response = try client.request(.{
        .method = .OPTIONS,
        .target = "*",
        .host = "localhost",
    });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 204), response.response.status);
    const allow = response.response.header("allow").?;
    try std.testing.expect(std.mem.indexOf(u8, allow, "GET") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "POST") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "OPTIONS") != null);

    server.stop();
    try group.await(io);
}

test "package: custom not-found and method-not-allowed handlers" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .not_found = weft.handler(customNotFound),
            .method_not_allowed = weft.handler(customMethodNotAllowed),
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/only", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{server.address().ip4.port},
    );
    defer allocator.free(base);

    const missing_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/missing",
        .{base},
    );
    defer allocator.free(missing_uri);
    var missing = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        missing_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), missing.response.status);
    try std.testing.expectEqualStrings(
        "{\"custom\":\"not_found\",\"status\":404}",
        missing.response.body,
    );

    const only_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/only",
        .{base},
    );
    defer allocator.free(only_uri);
    var denied = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        only_uri,
        .{ .method = .POST },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer denied.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 405), denied.response.status);
    try std.testing.expect(denied.response.header("allow") != null);
    try std.testing.expectEqualStrings(
        "{\"custom\":\"method_not_allowed\",\"allow\":\"GET, HEAD, OPTIONS\"}",
        denied.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: WebSocket upgrade echoes a message" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/ws", websocketRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    var client = try netz.websocket.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .host = "localhost", .target = "/ws" },
    );
    defer client.close();

    try client.sendText("hello websocket");
    var message = try client.receiveMessage();
    defer message.deinit(client.allocator);
    try std.testing.expectEqualStrings("hello websocket", message.payload);

    server.stop();
    try group.await(io);
}

test "package: WebSocket negotiates permessage-deflate" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/ws-compressed", websocketCompressedRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    var client = try netz.websocket.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{
            .host = "localhost",
            .target = "/ws-compressed",
            .enable_permessage_deflate = true,
        },
    );
    defer client.close();

    // Highly compressible payload so the client actually emits a compressed
    // frame; the server must decode it and echo the same bytes.
    const payload = try allocator.alloc(u8, 4096);
    defer allocator.free(payload);
    @memset(payload, 'c');

    try client.sendText(payload);
    var message = try client.receiveMessage();
    defer message.deinit(client.allocator);
    try std.testing.expectEqualSlices(u8, payload, message.payload);

    server.stop();
    try group.await(io);
}

test "package: multiple Set-Cookie headers are preserved" {
    const allocator = std.testing.allocator;

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
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/cookies", cookiesRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/cookies",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);
    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);

    var count: usize = 0;
    var saw_session = false;
    var saw_host = false;
    for (response.response.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "set-cookie")) continue;
        count += 1;
        if (std.mem.startsWith(u8, header.value, "session=abc;")) {
            saw_session = true;
            try std.testing.expect(std.mem.indexOf(
                u8,
                header.value,
                "HttpOnly",
            ) != null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                header.value,
                "SameSite=Lax",
            ) != null);
        }
        if (std.mem.startsWith(u8, header.value, "__Host-theme=dark;")) {
            saw_host = true;
            try std.testing.expect(std.mem.indexOf(
                u8,
                header.value,
                "Secure",
            ) != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(saw_session);
    try std.testing.expect(saw_host);

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

test "package: response header budget failure becomes 500" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
                .max_response_headers = 4,
                .max_response_head_bytes = 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().addRaw(
        .GET,
        "/headers",
        weft.handler(MethodHandlers.tooManyHeaders),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/headers",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 500), response.response.status);

    server.stop();
    try group.await(io);
}

test "package: Unix socket server serves HTTP/1" {
    if (comptime @import("builtin").os.tag == .windows) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(io, &path_storage);
    const suffix = try std.fmt.bufPrint(
        path_storage[directory_len..],
        "/weft-http.sock",
        .{},
    );
    const full_path = path_storage[0 .. directory_len + suffix.len];
    const address = try std.Io.net.UnixAddress.init(full_path);
    // The server owns the listener but not the filesystem entry.
    defer std.Io.Dir.deleteFileAbsolute(io, full_path) catch {};

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .unix_path = full_path,
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try std.testing.expect(server.ipAddress() == null);
    try std.testing.expectEqualStrings(full_path, server.unixPath().?);
    try server.router().get("/", home, .{});
    try server.router().get("/client", clientAddressText, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    var client = try netz.http1.runtime.Client.connectUnix(
        allocator,
        io,
        address,
        "localhost",
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();

    var response = try client.request(.{ .method = .GET, .target = "/" });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "hello from weft",
        response.response.body,
    );

    // std synthesizes 127.0.0.1 for Unix sockets; weft must not expose that
    // as a real peer address.
    var client_response = try client.request(.{
        .method = .GET,
        .target = "/client",
    });
    defer client_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        client_response.response.status,
    );
    try std.testing.expectEqualStrings("none", client_response.response.body);

    server.stop();
    try group.await(io);
}

test "package: server requires exactly one listen address" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    try std.testing.expectError(
        error.InvalidOptions,
        weft.Server(App).init(io, allocator, .{}, .{}),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .unix_path = "/tmp/weft-conflict.sock",
            },
            .{},
        ),
    );
}

test "package: servers reject unusable option budgets" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    try std.testing.expectError(
        error.InvalidOptions,
        weft.Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .limits = .{ .request_timeout = .fromSeconds(0) },
            },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .accept_error_backoff = .fromSeconds(0),
            },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .limits = .{ .max_request_target_bytes = 0 },
            },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Http2Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .limits = .{ .request_head_timeout = .fromSeconds(0) },
            },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Http2Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .limits = .{ .max_http2_concurrent_streams = 0 },
            },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Http2Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .max_handler_threads = 0,
            },
            .{},
        ),
    );
    if (@sizeOf(usize) > @sizeOf(u32)) {
        try std.testing.expectError(
            error.InvalidOptions,
            weft.Http2Server(App).init(
                io,
                allocator,
                .{
                    .address = .{ .ip4 = .loopback(0) },
                    .max_concurrent_handlers = @as(usize, std.math.maxInt(u32)) + 1,
                },
                .{},
            ),
        );
    }

    const connection_id = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Http3Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .handshake = .{
                    .local_connection_id = &connection_id,
                    .random = [_]u8{0} ** 32,
                    .x25519_secret_key = [_]u8{0} ** 32,
                },
                .limits = .{ .request_timeout = .fromSeconds(0) },
            },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Http3Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .handshake = .{
                    .local_connection_id = &connection_id,
                    .random = [_]u8{0} ** 32,
                    .x25519_secret_key = [_]u8{0} ** 32,
                },
                .limits = .{ .max_request_target_bytes = 0 },
            },
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Http3Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .handshake = .{
                    .local_connection_id = &connection_id,
                    .random = [_]u8{0} ** 32,
                    .x25519_secret_key = [_]u8{0} ** 32,
                },
                .max_handler_threads = 0,
            },
            .{},
        ),
    );
}

test "package: oversized request head and target return 431 and 414" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 512,
                .max_request_target_bytes = 32,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const address: std.Io.net.IpAddress = server.address();
    const client_limits: netz.http1.runtime.Limits = .{
        .max_head_bytes = 4096,
        .max_body_bytes = 4096,
    };

    // A single header field over max_head_bytes must still deliver 431; the
    // server answers and drains the unread head before closing.
    var big_value: [1024]u8 = undefined;
    @memset(&big_value, 'a');
    var client = try netz.http1.runtime.Client.connect(
        allocator,
        io,
        address,
        client_limits,
    );
    defer client.close();
    var response = try client.request(.{
        .method = .GET,
        .target = "/",
        .host = "localhost",
        .headers = &.{.{
            .name = "X-Oversized",
            .value = &big_value,
        }},
    });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 431), response.response.status);

    // A target over max_request_target_bytes maps to 414 through the same
    // write-drain-close path.
    var long_target: [128]u8 = undefined;
    @memset(&long_target, 'b');
    long_target[0] = '/';
    var client2 = try netz.http1.runtime.Client.connect(
        allocator,
        io,
        address,
        client_limits,
    );
    defer client2.close();
    var response2 = try client2.request(.{
        .method = .GET,
        .target = &long_target,
        .host = "localhost",
    });
    defer response2.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 414), response2.response.status);

    server.stop();
    try group.await(io);
}

test "package: HTTP/2 Unix socket serves h2c" {
    if (comptime @import("builtin").os.tag == .windows) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(io, &path_storage);
    const suffix = try std.fmt.bufPrint(
        path_storage[directory_len..],
        "/weft-h2.sock",
        .{},
    );
    const full_path = path_storage[0 .. directory_len + suffix.len];
    const address = try std.Io.net.UnixAddress.init(full_path);
    defer std.Io.Dir.deleteFileAbsolute(io, full_path) catch {};

    var server = try weft.Http2Server(App).init(
        io,
        allocator,
        .{
            .unix_path = full_path,
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
                .max_http2_concurrent_streams = 8,
            },
            .max_connections = 1,
            .max_concurrent_handlers = 8,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(500),
        },
        .{},
    );
    defer server.deinit();

    try std.testing.expect(server.ipAddress() == null);
    try std.testing.expectEqualStrings(full_path, server.unixPath().?);
    try server.router().get("/hello/:name", hello, .{});
    try server.router().get("/info", clientInfo, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    var client = try netz.http2.runtime.Client.connectUnix(
        allocator,
        io,
        address,
        "localhost",
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();

    var hello_response = try client.request(.{
        .method = "GET",
        .path = "/hello/weft",
    });
    defer hello_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), hello_response.status);
    try std.testing.expectEqualStrings(
        "{\"message\":\"hello\",\"name\":\"weft\"}",
        hello_response.body,
    );

    // A Unix socket has no IP peer; std's synthetic loopback must not leak.
    var info_response = try client.request(.{
        .method = "GET",
        .path = "/info",
    });
    defer info_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), info_response.status);
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"http_2\",\"has_address\":false,\"tls\":false}",
        info_response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: HTTP/2 server requires exactly one listen address" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    try std.testing.expectError(
        error.InvalidOptions,
        weft.Http2Server(App).init(io, allocator, .{}, .{}),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        weft.Http2Server(App).init(
            io,
            allocator,
            .{
                .address = .{ .ip4 = .loopback(0) },
                .unix_path = "/tmp/weft-h2-conflict.sock",
            },
            .{},
        ),
    );
}

test "package: HTTP/2 rejects an over-long request target" {
    const allocator = std.testing.allocator;

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
                .max_request_target_bytes = 32,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
                .max_http2_concurrent_streams = 4,
            },
            .max_connections = 1,
            .max_concurrent_handlers = 4,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(500),
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    var client = try netz.http2.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();

    var long_path: [64]u8 = undefined;
    @memset(&long_path, 'a');
    long_path[0] = '/';
    var response = try client.request(.{
        .method = "GET",
        .path = &long_path,
        .authority = "localhost",
    });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 414), response.status);

    // CONNECT has no tunnel writer in weft, so it must not be routed.
    var connect_response = try client.request(.{
        .method = "CONNECT",
        .path = "",
        .authority = "example.com:443",
    });
    defer connect_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 501), connect_response.status);

    server.stop();
    try group.await(io);
}

test "package: HTTP/2 per-route body budget returns 413" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
                .max_streaming_window_bytes = 512,
                .max_http2_concurrent_streams = 4,
            },
            .max_connections = 1,
            .max_concurrent_handlers = 4,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(500),
        },
        .{},
    );
    defer server.deinit();
    try server.router().post(
        "/upload",
        StreamHandlers.uploadRoute,
        .{ .streaming = true, .max_body_bytes = 1024 },
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    var client = try netz.http2.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();

    const body = try allocator.alloc(u8, 2048);
    defer allocator.free(body);
    @memset(body, 'x');
    var response = try client.request(.{
        .method = "POST",
        .path = "/upload",
        .authority = "localhost",
        .body = body,
    });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 413), response.status);

    server.stop();
    try group.await(io);
}

test "package: HTTP/1 answers Expect 100-continue for uploads" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();
    try server.router().post(
        "/upload",
        StreamHandlers.uploadRoute,
        .{ .streaming = true },
    );

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

    var response = try client.request(.{
        .method = .POST,
        .target = "/upload",
        .host = "localhost",
        .headers = &.{.{
            .name = "Expect",
            .value = "100-continue",
        }},
        .body = "hello",
    });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "{\"bytes\":5}",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: HTTP/1 CONNECT is rejected with 501" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
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

    var response = try client.request(.{
        .method = .CONNECT,
        .target = "example.com:443",
        .host = "example.com:443",
    });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 501), response.response.status);

    server.stop();
    try group.await(io);
}

test "package: HTTP/2 server body limit returns 413 and keeps the connection" {
    const allocator = std.testing.allocator;

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
                .max_body_bytes = 1024,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
                .max_streaming_window_bytes = 4096,
                .max_http2_concurrent_streams = 4,
            },
            .max_connections = 1,
            .max_concurrent_handlers = 4,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(500),
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/", home, .{});
    try server.router().post(
        "/upload",
        StreamHandlers.uploadRoute,
        .{ .streaming = true },
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    var client = try netz.http2.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();

    const body = try allocator.alloc(u8, 2048);
    defer allocator.free(body);
    @memset(body, 'x');
    var oversize = try client.request(.{
        .method = "POST",
        .path = "/upload",
        .authority = "localhost",
        .body = body,
    });
    defer oversize.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 413), oversize.status);

    // The rejected stream must not retire the connection.
    var sibling = try client.request(.{
        .method = "GET",
        .path = "/",
        .authority = "localhost",
    });
    defer sibling.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), sibling.status);
    try std.testing.expectEqualStrings("hello from weft", sibling.body);

    server.stop();
    try group.await(io);
}

const OrderState = struct {
    fn append(ctx: *weft.Ctx, suffix: []const u8) !void {
        const existing = ctx.responseHeader("x-order") orelse "";
        try ctx.setHeader(
            "X-Order",
            try std.fmt.allocPrint(
                ctx.arena,
                "{s}{s}",
                .{ existing, suffix },
            ),
        );
    }

    fn app(ctx: *weft.Ctx) anyerror!void {
        try append(ctx, "a");
        try ctx.next();
    }

    fn route(ctx: *weft.Ctx) anyerror!void {
        try append(ctx, "r");
        try ctx.next();
    }

    fn finalRoute(_: *App, ctx: *weft.Ctx) anyerror!void {
        try append(ctx, "h");
        try ctx.text("ok");
    }
};

test "package: route middleware runs after application middleware" {
    const allocator = std.testing.allocator;

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
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .middleware = &.{weft.handler(OrderState.app)},
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/order", OrderState.finalRoute, .{
        .middleware = &.{weft.handler(OrderState.route)},
    });

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/order",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);
    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings("ok", response.response.body);
    try std.testing.expectEqualStrings(
        "arh",
        response.response.header("x-order").?,
    );

    server.stop();
    try group.await(io);
}

test "package: HTTP/2 readBody survives a small request arena" {
    const allocator = std.testing.allocator;

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
                .max_body_bytes = 8192,
                .max_request_arena_bytes = 8192,
                .max_streaming_window_bytes = 512,
                .max_response_bytes = 4096,
            },
            .max_connections = 1,
            .max_concurrent_handlers = 4,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(100),
        },
        .{},
    );
    defer server.deinit();
    try server.router().post(
        "/read-body",
        StreamHandlers.readBodyRoute,
        .{ .streaming = true },
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{server.address().ip4.port},
    );
    defer allocator.free(base);
    const uri = try std.fmt.allocPrint(
        allocator,
        "{s}/read-body",
        .{base},
    );
    defer allocator.free(uri);

    // The reader yields 512-byte chunks. Without a staging buffer, arena
    // growth would leak intermediate blocks and exhaust the 8 KiB arena even
    // though the 6 KiB body fits.
    const body = try allocator.alloc(u8, 6000);
    defer allocator.free(body);
    @memset(body, 'x');
    var response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = "POST",
            .body = body,
        },
        .{ .max_frame_payload = 4096, .max_body_bytes = 8192 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{\"bytes\":6000}", response.body);

    server.stop();
    try group.await(io);
}

test "package: HTTP/2 buffered body survives a small request arena" {
    const allocator = std.testing.allocator;

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
                .max_request_arena_bytes = 4096,
                .max_response_bytes = 4096,
            },
            .max_connections = 1,
            .max_concurrent_handlers = 4,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(100),
        },
        .{},
    );
    defer server.deinit();
    try server.router().post("/body-echo", echoBufferedBody, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{server.address().ip4.port},
    );
    defer allocator.free(base);
    const uri = try std.fmt.allocPrint(
        allocator,
        "{s}/body-echo",
        .{base},
    );
    defer allocator.free(uri);

    // The declared length lets the adapter allocate the arena body exactly;
    // ArrayList growth would otherwise leak intermediate blocks.
    const body = try allocator.alloc(u8, 3000);
    defer allocator.free(body);
    @memset(body, 'x');
    var response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = "POST",
            .body = body,
        },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualSlices(u8, body, response.body);

    server.stop();
    try group.await(io);
}
