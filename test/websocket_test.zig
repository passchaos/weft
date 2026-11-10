const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const hello = support.hello;
const serveServer = support.serveServer;
const websocketCompressedRoute = support.websocketCompressedRoute;
const websocketRoute = support.websocketRoute;

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
