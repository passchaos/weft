const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;

const App = struct {};

fn echo(_: *App, ctx: *weft.grpc.Context) anyerror!void {
    try ctx.respond(ctx.message);
}

test "package: gRPC-Web unary adapter echoes a message" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.GrpcServer(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .grpc_web = true,
            .limits = .{
                .max_frame_payload = 4096,
                .max_body_bytes = 4096,
            },
            .max_connections = 1,
            .accept_timeout = .fromMilliseconds(500),
            .idle_timeout = .fromMilliseconds(200),
        },
        .{},
    );
    defer server.deinit();
    try server.route("/demo.Echo/Unary", echo);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serve, .{&server});

    var client = try netz.http2.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .max_frame_payload = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();

    const payload = "web-one";
    var body: [5 + payload.len]u8 = undefined;
    body[0] = 0;
    std.mem.writeInt(u32, body[1..5], @intCast(payload.len), .big);
    @memcpy(body[5..], payload);

    var response = try client.request(.{
        .method = "POST",
        .path = "/demo.Echo/Unary",
        .authority = "localhost",
        .headers = &.{
            .{ .name = "content-type", .value = "application/grpc-web" },
            .{ .name = "accept", .value = "application/grpc-web" },
            .{ .name = "x-grpc-web", .value = "1" },
        },
        .body = &body,
    });
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(response.body.len >= 5);
    try std.testing.expectEqual(
        @as(u32, payload.len),
        std.mem.readInt(u32, response.body[1..5], .big),
    );
    try std.testing.expectEqualStrings(
        payload,
        response.body[5 .. 5 + payload.len],
    );
    try std.testing.expect(
        std.mem.indexOf(u8, response.body, "grpc-status:0") != null,
    );

    server.stop();
    try group.await(io);
}

fn serve(server: *weft.GrpcServer(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn(
                "grpc web server failed: {s}",
                .{@errorName(err)},
            );
            return;
        },
    };
}
