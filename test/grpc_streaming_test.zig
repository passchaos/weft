const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;

const App = struct {};

fn stream(_: *App, ctx: *weft.grpc_streaming.Context) anyerror!void {
    const message = ctx.nextMessage() orelse "";
    try ctx.write(message);
    try ctx.write("second");
    try ctx.finish(.ok, null);
}

test "package: streaming gRPC writes multiple response messages" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.GrpcStreamingServer(App).init(
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
    try server.route("/demo.Echo/Stream", stream);

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

    var writer = try client.startStreaming(.{
        .path = "/demo.Echo/Stream",
        .authority = "localhost",
    });
    defer writer.deinit();
    try writer.writeMessage("stream-one");

    var messages: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (messages.items) |message| allocator.free(message);
        messages.deinit(allocator);
    }
    var collector = Collector{
        .allocator = allocator,
        .messages = &messages,
    };
    var response = try writer.finishAndRead(&collector, Collector.consume);
    defer response.deinit();

    try std.testing.expectEqual(netz.grpc.Status.ok, response.status);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("stream-one", messages.items[0]);
    try std.testing.expectEqualStrings("second", messages.items[1]);

    server.stop();
    try group.await(io);
}

const Collector = struct {
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged([]u8),

    fn consume(self: *Collector, message: netz.grpc.StreamingMessage) !void {
        const copy = try self.allocator.dupe(u8, message.payload);
        errdefer self.allocator.free(copy);
        try self.messages.append(self.allocator, copy);
    }
};

fn serve(server: *weft.GrpcStreamingServer(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn(
                "grpc streaming server failed: {s}",
                .{@errorName(err)},
            );
            return;
        },
    };
}
