const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;

const App = struct {};

fn echoSession(_: *App, session: *weft.WebTransportSession) anyerror!void {
    var datagram_storage: [64]u8 = undefined;
    const datagram = try session.receiveDatagramWithTimeout(
        &datagram_storage,
        .fromSeconds(3),
    );
    try session.sendDatagram(datagram);

    var stream = try session.receiveStreamWithTimeout(.fromSeconds(3));
    defer stream.deinit();
    try session.sendStream(stream.streamId(), stream.payload(), true);
    try session.close(0, "");
}

test "package: WebTransport echoes a datagram and a stream" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    const server_cid = [_]u8{ 0xea, 0xce, 0x20, 0x01 };
    const original_dcid = [_]u8{
        0xea, 0xce, 0x20, 0x02, 0xea, 0xce, 0x20, 0x03,
    };
    const client_cid = [_]u8{ 0xea, 0xce, 0x20, 0x04 };

    var server = try weft.WebTransportServer(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .http3 = .{
                    .quic = .{
                        .max_datagram_size = 4096,
                        .max_frames_per_datagram = 8,
                    },
                },
            },
            .handshake = .{
                .local_connection_id = &server_cid,
                .random = [_]u8{0x83} ** 32,
                .x25519_secret_key = [_]u8{0x84} ** 32,
            },
            .max_connections = 1,
            .accept_timeout = .fromMilliseconds(500),
            .max_stream_bytes = 64 * 1024,
            .max_datagram_bytes = 4096,
        },
        .{},
    );
    defer server.deinit();
    try server.route("/wt", echoSession);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serve, .{&server});

    var client = try netz.webtransport.runtime.HandshakeClientSession.connect(
        allocator,
        io,
        .{ .ip4 = .loopback(0) },
        server.address(),
        .{
            .authority = "localhost",
            .path = "/wt",
            .limits = .{
                .http3 = .{
                    .quic = .{
                        .max_datagram_size = 4096,
                        .max_frames_per_datagram = 8,
                    },
                },
            },
            .h3 = .{
                .handshake = .{
                    .original_destination_connection_id = &original_dcid,
                    .local_connection_id = &client_cid,
                    .server_name = "localhost",
                    .random = [_]u8{0x81} ** 32,
                    .x25519_secret_key = [_]u8{0x82} ** 32,
                },
            },
        },
    );
    defer client.deinit();

    try client.sendDatagram("wt-ping");
    var datagram_storage: [64]u8 = undefined;
    const datagram = try client.receiveDatagramIntoWithTimeout(
        &datagram_storage,
        .fromSeconds(3),
    );
    try std.testing.expectEqualStrings("wt-ping", datagram);

    const stream_id = try client.openBidirectionalStream();
    try client.sendStream(stream_id, "wt-stream", true);
    var stream = try client.receiveStreamWithTimeout(.fromSeconds(3));
    defer stream.deinit();
    try std.testing.expectEqual(stream_id, stream.stream_id);
    try std.testing.expectEqualStrings("wt-stream", stream.payload);

    server.stop();
    try group.await(io);
}

fn serve(server: *weft.WebTransportServer(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn(
                "webtransport server failed: {s}",
                .{@errorName(err)},
            );
            return;
        },
    };
}
