const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const hello = support.hello;
const serveServer = support.serveServer;
const upload = support.upload;

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
