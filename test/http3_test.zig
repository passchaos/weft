const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const StreamHandlers = support.StreamHandlers;
const clientInfo = support.clientInfo;
const cookiesRoute = support.cookiesRoute;
const echoJson = support.echoJson;
const h3Header = support.h3Header;
const hello = support.hello;
const home = support.home;
const serveHttp3Server = support.serveHttp3Server;
const streamingTrailerRoute = support.streamingTrailerRoute;
const trailerRoute = support.trailerRoute;
const upload = support.upload;
const websocketRoute = support.websocketRoute;

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

test "package: HTTP/3 inline bodyless route and body fallback" {
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
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
                .max_streaming_window_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .max_concurrent_streams = 8,
            .max_concurrent_handlers = 8,
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
    try router.get("/inline", home, .{ .inline_bodyless = true });
    try router.post(
        "/inline-echo",
        echoJson,
        .{ .inline_bodyless = true },
    );

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

    var inline_response = try client.request(.{
        .method = "GET",
        .path = "/inline",
        .authority = "localhost",
    });
    defer inline_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 200),
        inline_response.response.status,
    );
    try std.testing.expectEqualStrings(
        "hello from weft",
        inline_response.response.body,
    );

    var echo_headers = [_]netz.http3.Qpack.HeaderField{.{
        .name = "content-type",
        .value = "application/json",
    }};
    var echo_response = try client.request(.{
        .method = "POST",
        .path = "/inline-echo",
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

test "package: HTTP/3 sends 103 Early Hints before the final response" {
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
            .max_concurrent_streams = 8,
            .max_concurrent_handlers = 8,
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
    try router.get("/hints", earlyHintsRoute, .{});

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

    const Observer = struct {
        status: u16 = 0,
        link_buf: [128]u8 = undefined,
        link_len: usize = 0,

        fn on(raw: *anyopaque, head: netz.http3.InformationalResponseHead) void {
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
    var response = try client.requestWithInformational(
        .{
            .method = "GET",
            .path = "/hints",
            .authority = "localhost",
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

test "package: HTTP/3 WebSocket extended CONNECT echoes a message" {
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
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .max_concurrent_streams = 4,
            .max_concurrent_handlers = 4,
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
    try router.get("/ws", websocketRoute, .{});

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

    var ws = netz.websocket.runtime.h3.Client.connectSessionWithTimeout(
        allocator,
        &client,
        .{
            .authority = "localhost",
            .path = "/ws",
        },
        .fromSeconds(3),
    ) catch |err| {
        client.deinit();
        return err;
    };
    defer ws.deinit();

    try ws.sendText("hello over h3");
    var message = try ws.receiveMessageWithTimeout(.fromSeconds(3));
    defer message.deinit(allocator);
    try std.testing.expectEqualStrings("hello over h3", message.payload);

    server.stop();
    try group.await(io);
}
