const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const MethodHandlers = support.MethodHandlers;
const StreamHandlers = support.StreamHandlers;
const bufferedTrailerEcho = support.bufferedTrailerEcho;
const clientAddressText = support.clientAddressText;
const clientInfo = support.clientInfo;
const cookiesRoute = support.cookiesRoute;
const deadlineInfo = support.deadlineInfo;
const echoJson = support.echoJson;
const gzipAlloc = support.gzipAlloc;
const hello = support.hello;
const home = support.home;
const serveServer = support.serveServer;
const slowHandler = support.slowHandler;
const streamingTrailerEcho = support.streamingTrailerEcho;
const streamingTrailerRoute = support.streamingTrailerRoute;
const trailerRoute = support.trailerRoute;
const upload = support.upload;

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

fn earlyHintsRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.sendEarlyHints(&.{
        .{ .name = "Link", .value = "</style.css>; rel=preload" },
    });
    try ctx.text("ok");
}

test "package: HTTP/1 sends 103 Early Hints before the final response" {
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
            .max_requests_per_connection = 1,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/hints", earlyHintsRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const Observer = struct {
        status: u16 = 0,
        link_buf: [128]u8 = undefined,
        link_len: usize = 0,

        fn on(raw: *anyopaque, head: netz.http1.runtime.InformationalResponseHead) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.status = head.status;
            if (head.header("link")) |link| {
                const len = @min(link.len, self.link_buf.len);
                @memcpy(self.link_buf[0..len], link[0..len]);
                self.link_len = len;
            }
        }
    };
    var observer = Observer{};
    var client = try netz.http1.runtime.Client.connect(
        allocator,
        io,
        .{ .ip4 = .loopback(server.address().ip4.port) },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();
    var response = try client.requestWithInformational(
        .{
            .method = .GET,
            .target = "/hints",
            .host = "127.0.0.1",
        },
        .{ .context = &observer, .on_response = Observer.on },
    );
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 103), observer.status);
    try std.testing.expectEqualStrings(
        "</style.css>; rel=preload",
        observer.link_buf[0..observer.link_len],
    );
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings("ok", response.response.body);

    server.stop();
    try group.await(io);
}
