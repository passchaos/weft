const std = @import("std");
const netz = @import("netz");

/// A live RFC 6455 session owned by the server worker for its lifetime.
///
/// HTTP/1.1 sessions wrap a netz TCP/TLS connection. HTTP/2 extended CONNECT
/// and HTTP/3 sessions wrap a generic stream connection.
pub const Session = struct {
    pub const Inner = union(enum) {
        http1: netz.websocket.runtime.Connection,
        stream: netz.websocket.stream_connection.Connection,
    };

    inner: Inner,
    /// True once a close frame has been written, so `close` does not send a
    /// second one.
    close_frame_sent: bool = false,

    pub const CloseCode = netz.websocket.CloseCode;

    pub fn sendText(self: *Session, text: []const u8) !void {
        switch (self.inner) {
            .http1 => |*connection| try connection.sendText(text),
            .stream => |*connection| try connection.sendText(text),
        }
    }

    pub fn sendBinary(self: *Session, data: []const u8) !void {
        switch (self.inner) {
            .http1 => |*connection| try connection.sendMessage(.binary, data),
            .stream => |*connection| try connection.sendBinary(data),
        }
    }

    pub fn sendPing(self: *Session, payload: []const u8) !void {
        switch (self.inner) {
            .http1 => |*connection| try connection.sendPing(payload),
            .stream => |*connection| try connection.sendPing(payload),
        }
    }

    pub fn sendPong(self: *Session, payload: []const u8) !void {
        switch (self.inner) {
            .http1 => |*connection| try connection.sendPong(payload),
            .stream => |*connection| try connection.sendPong(payload),
        }
    }

    /// Write a close frame. Call `close` afterwards to release the transport.
    pub fn sendClose(
        self: *Session,
        code: CloseCode,
        reason: []const u8,
    ) !void {
        switch (self.inner) {
            .http1 => |*connection| try connection.sendClose(code, reason),
            .stream => |*connection| try connection.sendClose(code, reason),
        }
        self.close_frame_sent = true;
    }

    /// Frame-level receive is only available on the HTTP/1.1 transport.
    pub fn receiveFrame(self: *Session) !netz.websocket.Frame {
        return switch (self.inner) {
            .http1 => |*connection| connection.receiveFrame(),
            .stream => error.Unsupported,
        };
    }

    pub const Message = struct {
        opcode: netz.websocket.Opcode,
        payload: []const u8,
        owner: union(enum) {
            http1: netz.websocket.runtime.OwnedMessage,
            stream: []u8,
        },
    };

    pub fn receiveMessage(self: *Session) !Message {
        return switch (self.inner) {
            .http1 => |*connection| blk: {
                const owned = try connection.receiveMessage();
                break :blk .{
                    .opcode = owned.opcode,
                    .payload = owned.payload,
                    .owner = .{ .http1 = owned },
                };
            },
            .stream => |*connection| blk: {
                const message = try connection.receiveMessage();
                break :blk .{
                    .opcode = message.opcode,
                    .payload = message.payload,
                    .owner = .{ .stream = message.payload },
                };
            },
        };
    }

    /// Release an owned message returned by `receiveMessage`.
    pub fn deinitMessage(self: *Session, message: *Message) void {
        switch (message.owner) {
            .http1 => |*owned| switch (self.inner) {
                .http1 => |*connection| owned.deinit(connection.allocator),
                .stream => unreachable,
            },
            .stream => |payload| switch (self.inner) {
                .stream => |*connection| connection.allocator.free(payload),
                .http1 => unreachable,
            },
        }
        message.* = undefined;
    }

    /// Send a normal closure frame when possible, then release the transport.
    pub fn close(self: *Session) void {
        switch (self.inner) {
            .http1 => |*connection| {
                if (!self.close_frame_sent) {
                    connection.sendClose(.normal_closure, "") catch {};
                    self.close_frame_sent = true;
                }
                connection.close();
            },
            // The HTTP/2/3 stream is retired by the adapter after the handler
            // returns; writing a close frame here races the peer's reset.
            .stream => |*connection| connection.deinit(),
        }
    }
};

/// A handler selected by `Ctx.upgradeWebSocket`. The session runs synchronously
/// after the HTTP 101 (HTTP/1.1) or 200 (HTTP/2/3 extended CONNECT) response.
pub const Upgrade = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (?*anyopaque, *Session) anyerror!void,
    /// Optional subprotocol selected by the server. The client must have
    /// offered it in `Sec-WebSocket-Protocol`.
    subprotocol: ?[]const u8 = null,
    /// Negotiate RFC 7692 `permessage-deflate` when the client offers it.
    /// The 101 response advertises the accepted parameters and the session
    /// compresses messages at or above `compression_threshold` bytes.
    compression: bool = false,
    compression_threshold: usize = 32,
    /// Releases resources if the upgrade response is discarded before the
    /// session starts.
    cancel_fn: ?*const fn (?*anyopaque) void = null,

    pub fn run(self: *const Upgrade, session: *Session) anyerror!void {
        return self.run_fn(self.context, session);
    }

    pub fn cancel(self: *const Upgrade) void {
        if (self.cancel_fn) |cancel_fn| cancel_fn(self.context);
    }
};

/// Validates the RFC 6455 opening handshake for an HTTP/1.1 request.
pub fn validWebSocketUpgrade(
    request: *const netz.http1.Request,
    subprotocol: ?[]const u8,
) bool {
    if (request.method != .GET or
        request.version != .http_1_1 or
        request.body.len != 0 or
        request.trailers.len != 0)
    {
        return false;
    }

    const protocol = request.upgradeProtocol() orelse return false;
    if (!std.ascii.eqlIgnoreCase(protocol, "websocket")) return false;

    const client_key = request.header("sec-websocket-key") orelse return false;
    netz.websocket.validateClientKey(client_key) catch return false;

    const version = request.header("sec-websocket-version") orelse return false;
    if (!std.mem.eql(u8, version, "13")) return false;

    if (subprotocol) |selected| {
        if (!netz.websocket.validSubprotocolToken(selected)) return false;
        if (!offeredSubprotocol(request, selected)) return false;
    }
    return true;
}

fn offeredSubprotocol(
    request: *const netz.http1.Request,
    selected: []const u8,
) bool {
    const header = request.header("sec-websocket-protocol") orelse return false;
    var parts = std.mem.splitScalar(u8, header, ',');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t"), selected)) {
            return true;
        }
    }
    return false;
}
