const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const gzipAlloc = support.gzipAlloc;
const serveServer = support.serveServer;

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
