const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const certificateCount = support.certificateCount;
const hello = support.hello;
const home = support.home;
const serveServer = support.serveServer;

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

test "package: one TLS port negotiates h2 and http/1.1 via ALPN" {
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
            .tls = .{
                .identity = .{
                    .certificate_chain = &.{&certificate_der},
                    .signer = .{ .ecdsa_p256_sha256 = .{
                        .key_pair = key_pair,
                    } },
                },
            },
            .alpn_http1 = true,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/", home, .{});
    try router.get("/hello/:name", hello, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, support.serveHttp2Server, .{&server});

    const address = server.address();
    const limits = netz.http1.runtime.Limits{
        .max_head_bytes = 4096,
        .max_body_bytes = 4096,
    };

    const http1_stream = try address.connect(io, .{ .mode = .stream });
    const http1_tls = try netz.tls.stream.ClientConnection.init(
        allocator,
        io,
        http1_stream,
        .{
            .server_name = "127.0.0.1",
            .server_verifier = .{
                .pinned_ecdsa_p256_public_key = key_pair.public_key.toUncompressedSec1(),
            },
            .alpn_protocols = &.{"http/1.1"},
        },
    );
    var http1_client = try netz.http1.runtime.Client.adoptNegotiatedTls(
        allocator,
        io,
        http1_tls,
        "127.0.0.1",
        limits,
    );
    defer http1_client.close();
    var http1_response = try http1_client.request(.{
        .method = .GET,
        .target = "/",
    });
    defer http1_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), http1_response.response.status);
    try std.testing.expectEqualStrings(
        "hello from weft",
        http1_response.response.body,
    );

    const h2_stream = try address.connect(io, .{ .mode = .stream });
    const h2_tls = try netz.tls.stream.ClientConnection.init(
        allocator,
        io,
        h2_stream,
        .{
            .server_name = "127.0.0.1",
            .server_verifier = .{
                .pinned_ecdsa_p256_public_key = key_pair.public_key.toUncompressedSec1(),
            },
            .alpn_protocols = &.{"h2"},
        },
    );
    var h2_client = try netz.http2.runtime.Client.adoptNegotiatedTls(
        allocator,
        io,
        h2_tls,
        "127.0.0.1",
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer h2_client.close();
    var h2_response = try h2_client.request(.{
        .path = "/hello/alpn",
        .authority = "127.0.0.1",
    });
    defer h2_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), h2_response.status);
    try std.testing.expectEqualStrings(
        "{\"message\":\"hello\",\"name\":\"alpn\"}",
        h2_response.body,
    );

    server.stop();
    try group.await(io);
}
