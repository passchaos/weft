const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const StreamHandlers = support.StreamHandlers;
const clientInfo = support.clientInfo;
const cookiesRoute = support.cookiesRoute;
const echoBufferedBody = support.echoBufferedBody;
const echoJson = support.echoJson;
const h2Header = support.h2Header;
const hello = support.hello;
const home = support.home;
const serveHttp2Server = support.serveHttp2Server;
const streamingTrailerEcho = support.streamingTrailerEcho;
const streamingTrailerRoute = support.streamingTrailerRoute;
const trailerRoute = support.trailerRoute;
const upload = support.upload;

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

test "package: HTTP/2 inline bodyless route and body fallback" {
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
                .max_http2_concurrent_streams = 8,
            },
            .max_connections = 1,
            .max_concurrent_handlers = 8,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(100),
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/inline", home, .{ .inline_bodyless = true });
    try router.post(
        "/inline-echo",
        echoJson,
        .{ .inline_bodyless = true },
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

    const inline_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/inline",
        .{base},
    );
    defer allocator.free(inline_uri);
    var inline_response = try netz.http2.runtime.Client.requestUri(
        allocator,
        io,
        inline_uri,
        .{},
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer inline_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), inline_response.status);
    try std.testing.expectEqualStrings(
        "hello from weft",
        inline_response.body,
    );

    const echo_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/inline-echo",
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

test "package: HTTP/2 sends 103 Early Hints before the final response" {
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
            },
            .max_connections = 1,
            .max_concurrent_handlers = 4,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(100),
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/hints", earlyHintsRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    const Observer = struct {
        status: u16 = 0,
        link_buf: [128]u8 = undefined,
        link_len: usize = 0,

        fn on(raw: *anyopaque, head: netz.http2.runtime.StreamingResponseHead) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.status = head.status;
            for (head.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "link")) {
                    const len = @min(header.value.len, self.link_buf.len);
                    @memcpy(self.link_buf[0..len], header.value[0..len]);
                    self.link_len = len;
                }
            }
        }
    };
    var observer = Observer{};
    var client = try netz.http2.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();
    var response = try client.requestWithInformational(
        .{ .path = "/hints", .authority = "localhost" },
        .{ .context = &observer, .on_response = Observer.on },
    );
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 103), observer.status);
    try std.testing.expectEqualStrings(
        "</style.css>; rel=preload",
        observer.link_buf[0..observer.link_len],
    );
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("ok", response.body);

    server.stop();
    try group.await(io);
}

fn upgradeRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("upgraded");
}

test "package: HTTP/2 accepts HTTP/1.1 h2c Upgrade" {
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
            },
            .max_connections = 1,
            .max_concurrent_handlers = 4,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(100),
            .h2c_upgrade = true,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/upgrade", upgradeRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/upgrade",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http2.runtime.Client.requestUriUpgrade(
        allocator,
        io,
        uri,
        .{ .method = "GET" },
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("upgraded", response.body);

    server.stop();
    try group.await(io);
}

fn wsEcho(_: ?*anyopaque, session: *weft.WebSocketSession) anyerror!void {
    var message = try session.receiveMessage();
    defer session.deinitMessage(&message);
    try session.sendText(message.payload);
}

fn wsRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.upgradeWebSocket(.{ .run_fn = wsEcho });
}

test "package: HTTP/2 WebSocket extended CONNECT echoes a message" {
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
                .http2_enable_connect_protocol = true,
            },
            .max_connections = 1,
            .max_concurrent_handlers = 4,
            .accept_timeout = .fromMilliseconds(100),
            .idle_timeout = .fromMilliseconds(100),
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/ws", wsRoute, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveHttp2Server, .{&server});

    var client = try netz.http2.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{
            .max_frame_payload = 4096,
            .max_body_bytes = 4096,
            .enable_connect_protocol = true,
        },
    );
    defer client.close();

    var ws = try netz.websocket.runtime.H2Client.open(
        allocator,
        &client,
        .{
            .path = "/ws",
            .authority = "127.0.0.1",
        },
    );
    defer ws.close();

    try ws.sendText("hello over h2");
    var message = try ws.receiveMessage();
    defer message.deinit(allocator);
    try std.testing.expectEqualStrings("hello over h2", message.payload);

    server.stop();
    try group.await(io);
}
