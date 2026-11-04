const std = @import("std");
const netz = @import("netz");

/// A live RFC 6455 session owned by the server worker for its lifetime.
pub const Session = struct {
    connection: netz.websocket.runtime.Connection,
    /// True once a close frame has been written, so `close` does not send a
    /// second one.
    close_frame_sent: bool = false,

    pub const CloseCode = netz.websocket.CloseCode;

    pub fn sendText(self: *Session, text: []const u8) !void {
        try self.connection.sendText(text);
    }

    pub fn sendBinary(self: *Session, data: []const u8) !void {
        try self.connection.sendMessage(.binary, data);
    }

    pub fn sendPing(self: *Session, payload: []const u8) !void {
        try self.connection.sendPing(payload);
    }

    pub fn sendPong(self: *Session, payload: []const u8) !void {
        try self.connection.sendPong(payload);
    }

    /// Write a close frame. Call `close` afterwards to release the transport.
    pub fn sendClose(
        self: *Session,
        code: CloseCode,
        reason: []const u8,
    ) !void {
        try self.connection.sendClose(code, reason);
        self.close_frame_sent = true;
    }

    pub fn receiveFrame(self: *Session) !netz.websocket.Frame {
        return self.connection.receiveFrame();
    }

    pub fn receiveMessage(self: *Session) !netz.websocket.runtime.OwnedMessage {
        return self.connection.receiveMessage();
    }

    /// Release an owned message returned by `receiveMessage`.
    pub fn deinitMessage(
        self: *Session,
        message: *netz.websocket.runtime.OwnedMessage,
    ) void {
        message.deinit(self.connection.allocator);
    }

    /// Send a normal closure frame when possible, then release the transport.
    pub fn close(self: *Session) void {
        if (!self.close_frame_sent) {
            self.connection.sendClose(.normal_closure, "") catch {};
            self.close_frame_sent = true;
        }
        self.connection.close();
    }
};

/// A handler selected by `Ctx.upgradeWebSocket`. The session runs synchronously
/// on the connection worker after the HTTP 101 response.
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
