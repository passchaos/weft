const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;

const App = struct {};

fn echo(_: *App, ctx: *weft.grpc.Context) anyerror!void {
    try ctx.respond(ctx.message);
}

fn fail(_: *App, ctx: *weft.grpc.Context) anyerror!void {
    _ = ctx;
    return error.Boom;
}

fn missing(_: *App, ctx: *weft.grpc.Context) anyerror!void {
    try ctx.respondStatus(.not_found, "missing");
}

test "package: gRPC unary adapter dispatches and reuses a channel" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.GrpcServer(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
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
    try server.route("/demo.Echo/Fail", fail);
    try server.route("/demo.Echo/Missing", missing);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serve, .{&server});

    var client = try netz.grpc.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{
            .max_frame_payload = 4096,
            .max_body_bytes = 4096,
        },
    );
    defer client.deinit();

    var first = try client.unary(.{
        .path = "/demo.Echo/Unary",
        .authority = "localhost",
        .message = "grpc-one",
    });
    defer first.deinit();
    try std.testing.expectEqual(netz.grpc.Status.ok, first.status);
    try std.testing.expectEqualStrings("grpc-one", first.message.?.payload);

    var second = try client.unary(.{
        .path = "/demo.Echo/Unary",
        .authority = "localhost",
        .message = "grpc-two",
    });
    defer second.deinit();
    try std.testing.expectEqual(netz.grpc.Status.ok, second.status);
    try std.testing.expectEqualStrings("grpc-two", second.message.?.payload);

    var unimplemented = try client.unary(.{
        .path = "/demo.Echo/Unknown",
        .authority = "localhost",
        .message = "x",
    });
    defer unimplemented.deinit();
    try std.testing.expectEqual(
        netz.grpc.Status.unimplemented,
        unimplemented.status,
    );

    var failed = try client.unary(.{
        .path = "/demo.Echo/Fail",
        .authority = "localhost",
        .message = "x",
    });
    defer failed.deinit();
    try std.testing.expectEqual(netz.grpc.Status.internal, failed.status);

    var not_found = try client.unary(.{
        .path = "/demo.Echo/Missing",
        .authority = "localhost",
        .message = "x",
    });
    defer not_found.deinit();
    try std.testing.expectEqual(
        netz.grpc.Status.not_found,
        not_found.status,
    );

    server.stop();
    try group.await(io);
}

fn serve(server: *weft.GrpcServer(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn(
                "grpc server failed: {s}",
                .{@errorName(err)},
            );
            return;
        },
    };
}
