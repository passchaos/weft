const std = @import("std");
const netz = @import("netz");
const drain_mod = @import("drain.zig");
const logging_mod = @import("logging.zig");

pub const Direction = netz.webtransport.StreamDirection;
pub const StreamRead = netz.webtransport.runtime.StreamRead;

pub const Options = struct {
    address: std.Io.net.IpAddress,
    limits: netz.webtransport.runtime.Limits = .{},
    /// QUIC/TLS server identity and randomness.
    handshake: netz.quic.handshake.ServerOptions,
    session: netz.http3.runtime.HandshakeSessionOptions = .{},
    max_connections: usize = 64,
    accept_timeout: std.Io.Duration = .fromMilliseconds(500),
    accept_error_backoff: std.Io.Duration = .fromMilliseconds(10),
    /// Bound for one whole stream received by `Session.receiveStream`.
    max_stream_bytes: usize = 1024 * 1024,
    /// Bound for one datagram sent by `Session.sendDatagram`.
    max_datagram_bytes: usize = 64 * 1024,
    drain_timeout: ?std.Io.Duration = .fromSeconds(5),
};

/// One accepted WebTransport session.
///
/// The wrapper exposes datagrams and streams without leaking netz connection
/// state. Handlers run synchronously for the lifetime of the session.
pub const Session = struct {
    inner: *netz.webtransport.runtime.AcceptedHandshakeSession,
    max_stream_bytes: usize,
    max_datagram_bytes: usize,

    pub fn path(self: *const Session) []const u8 {
        return self.inner.request.request.path;
    }

    pub fn authority(self: *const Session) ?[]const u8 {
        return self.inner.request.request.authority;
    }

    pub fn origin(self: *const Session) ?[]const u8 {
        for (self.inner.request.request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
                return header.value;
            }
        }
        return null;
    }

    pub fn userAgent(self: *const Session) ?[]const u8 {
        for (self.inner.request.request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
                return header.value;
            }
        }
        return null;
    }

    pub fn headers(self: *const Session) []const netz.http3.Qpack.HeaderField {
        return self.inner.request.request.headers;
    }

    pub fn remoteAddress(self: *const Session) std.Io.net.IpAddress {
        return self.inner.remoteAddress();
    }

    pub fn peerCertificates(self: *const Session) ?[]const []const u8 {
        return self.inner.peerCertificates();
    }

    pub fn applicationProtocol(self: *const Session) ?[]const u8 {
        const protocol = self.inner.applicationProtocol() orelse return null;
        return protocol.raw;
    }

    pub fn sessionId(self: *const Session) u62 {
        return self.inner.sessionId().value;
    }

    pub fn maxDatagramSize(self: *const Session) usize {
        return self.inner.maxDatagramSize();
    }

    pub fn sendDatagram(self: *Session, payload: []const u8) !void {
        const negotiated = self.inner.maxDatagramSize();
        if (negotiated == 0) return error.DatagramsNotNegotiated;
        if (payload.len > @min(self.max_datagram_bytes, negotiated)) {
            return error.DatagramTooLarge;
        }
        return self.inner.sendDatagram(payload);
    }

    pub fn sendDatagramWithTimeout(
        self: *Session,
        payload: []const u8,
        timeout: std.Io.Duration,
    ) !void {
        const negotiated = self.inner.maxDatagramSize();
        if (negotiated == 0) return error.DatagramsNotNegotiated;
        if (payload.len > @min(self.max_datagram_bytes, negotiated)) {
            return error.DatagramTooLarge;
        }
        return self.inner.sendDatagramWithTimeout(payload, timeout);
    }

    pub fn receiveDatagram(self: *Session, output: []u8) ![]u8 {
        return self.inner.receiveDatagramInto(output);
    }

    pub fn receiveDatagramWithTimeout(
        self: *Session,
        output: []u8,
        timeout: std.Io.Duration,
    ) ![]u8 {
        return self.inner.receiveDatagramIntoWithTimeout(output, timeout);
    }

    pub fn openBidirectionalStream(self: *Session) !u62 {
        return self.inner.openBidirectionalStream();
    }

    pub fn openUnidirectionalStream(self: *Session) !u62 {
        return self.inner.openUnidirectionalStream();
    }

    pub fn sendStream(
        self: *Session,
        stream_id: u62,
        payload: []const u8,
        fin: bool,
    ) !void {
        if (payload.len > self.max_stream_bytes) return error.StreamTooLarge;
        return self.inner.sendStream(stream_id, payload, fin);
    }

    pub fn sendStreamWithTimeout(
        self: *Session,
        stream_id: u62,
        payload: []const u8,
        fin: bool,
        timeout: std.Io.Duration,
    ) !void {
        if (payload.len > self.max_stream_bytes) return error.StreamTooLarge;
        return self.inner.sendStreamWithTimeout(
            stream_id,
            payload,
            fin,
            timeout,
        );
    }

    pub fn receiveStream(self: *Session) !Stream {
        return .{ .inner = try self.inner.receiveStream() };
    }

    pub fn receiveStreamWithTimeout(
        self: *Session,
        timeout: std.Io.Duration,
    ) !Stream {
        return .{ .inner = try self.inner.receiveStreamWithTimeout(timeout) };
    }

    pub fn readStream(self: *Session, output: []u8) !StreamRead {
        return self.inner.readStream(output);
    }

    pub fn readStreamWithTimeout(
        self: *Session,
        output: []u8,
        timeout: std.Io.Duration,
    ) !StreamRead {
        return self.inner.readStreamWithTimeout(output, timeout);
    }

    pub fn finishStream(self: *Session, stream_id: u62) !void {
        return self.inner.finishStream(stream_id);
    }

    pub fn resetStream(self: *Session, stream_id: u62, code: u32) !void {
        return self.inner.resetStream(stream_id, code);
    }

    pub fn close(self: *Session, code: u32, reason: []const u8) !void {
        return self.inner.close(code, reason);
    }

    pub fn drain(self: *Session) !void {
        return self.inner.drain();
    }
};

/// One whole received stream. The payload is owned by the value.
pub const Stream = struct {
    inner: netz.webtransport.runtime.OwnedHandshakeStream,

    pub fn deinit(self: *Stream) void {
        self.inner.deinit();
        self.* = undefined;
    }

    pub fn streamId(self: *const Stream) u62 {
        return self.inner.stream_id;
    }

    pub fn direction(self: *const Stream) Direction {
        return self.inner.direction;
    }

    pub fn locallyInitiated(self: *const Stream) bool {
        return self.inner.locally_initiated;
    }

    pub fn payload(self: *const Stream) []const u8 {
        return self.inner.payload;
    }

    pub fn fin(self: *const Stream) bool {
        return self.inner.fin;
    }
};

/// WebTransport server adapter over netz's QUIC/TLS handshake runtime.
///
/// One application handler runs per accepted session. Route paths are matched
/// exactly; use `setFallback` for dynamic paths and parse them inside the
/// handler.
pub fn WebTransportServer(comptime H: type) type {
    comptime {
        if (H == void) {
            @compileError(
                "weft.WebTransportServer requires a non-void app context; use an empty struct",
            );
        }
    }
    return struct {
        const Self = @This();

        pub const Handler = *const fn (*H, *Session) anyerror!void;

        io: std.Io,
        allocator: std.mem.Allocator,
        app: H,
        options: Options,
        netz_server: netz.webtransport.runtime.HandshakeServer,
        routes: std.StringHashMapUnmanaged(Handler) = .empty,
        fallback_handler: ?Handler = null,
        shutdown: std.Io.Event = .unset,

        pub fn init(
            io: std.Io,
            allocator: std.mem.Allocator,
            options: Options,
            app: H,
        ) !Self {
            if (options.max_connections == 0 or
                options.accept_timeout.nanoseconds <= 0 or
                options.accept_error_backoff.nanoseconds <= 0 or
                options.max_stream_bytes == 0 or
                options.max_datagram_bytes == 0 or
                (options.drain_timeout != null and
                    options.drain_timeout.?.nanoseconds <= 0))
            {
                return error.InvalidOptions;
            }
            var limits = options.limits;
            limits.http3.max_stream_buffer = options.max_stream_bytes;
            const netz_server = try netz.webtransport.runtime.HandshakeServer.bind(
                allocator,
                io,
                options.address,
                limits,
                .{
                    .handshake = options.handshake,
                    .session = options.session,
                },
            );
            return .{
                .io = io,
                .allocator = allocator,
                .app = app,
                .options = options,
                .netz_server = netz_server,
            };
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.routes.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.routes.deinit(self.allocator);
            self.netz_server.deinit();
            self.* = undefined;
        }

        pub fn address(self: *const Self) std.Io.net.IpAddress {
            return self.netz_server.address();
        }

        pub fn route(
            self: *Self,
            path: []const u8,
            handler: Handler,
        ) !void {
            if (path.len == 0 or path[0] != '/') return error.InvalidPath;
            if (self.routes.contains(path)) return error.DuplicateRoute;
            const owned = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned);
            try self.routes.put(self.allocator, owned, handler);
        }

        pub fn setFallback(self: *Self, handler: Handler) void {
            self.fallback_handler = handler;
        }

        pub fn stop(self: *Self) void {
            self.shutdown.set(self.io);
        }

        pub fn serve(self: *Self) !void {
            var semaphore = std.Io.Semaphore{
                .permits = self.options.max_connections,
            };
            var group: std.Io.Group = .init;
            var group_finished = false;
            defer if (!group_finished) group.cancel(self.io);

            try group.concurrent(self.io, acceptWorker, .{
                self,
                &group,
                &semaphore,
            });

            self.shutdown.wait(self.io) catch |err| {
                group.cancel(self.io);
                group_finished = true;
                return err;
            };

            drain_mod.awaitGroup(
                self.io,
                &group,
                self.options.drain_timeout,
            ) catch |err| {
                group.cancel(self.io);
                group_finished = true;
                return err;
            };
            group_finished = true;
        }

        fn acceptWorker(
            self: *Self,
            group: *std.Io.Group,
            semaphore: *std.Io.Semaphore,
        ) std.Io.Cancelable!void {
            while (true) {
                if (self.shutdown.isSet()) return;
                try semaphore.wait(self.io);

                var pending = self.netz_server.receiveSessionRequestWithTimeout(
                    self.options.accept_timeout,
                ) catch |err| {
                    semaphore.post(self.io);
                    if (err == error.Canceled) return error.Canceled;
                    if (err == error.Timeout) continue;
                    if (self.shutdown.isSet()) return;
                    logging_mod.logWarn(
                        "weft",
                        "webtransport accept failed: {s}",
                        .{@errorName(err)},
                        .{ .err = @errorName(err) },
                    );
                    std.Io.sleep(
                        self.io,
                        self.options.accept_error_backoff,
                        .awake,
                    ) catch return error.Canceled;
                    continue;
                };

                const handler = self.routes.get(pending.path()) orelse
                    self.fallback_handler orelse {
                    pending.deinit();
                    semaphore.post(self.io);
                    continue;
                };
                const session = pending.accept() catch |err| {
                    pending.deinit();
                    semaphore.post(self.io);
                    logging_mod.logWarn(
                        "weft",
                        "webtransport accept failed: {s}",
                        .{@errorName(err)},
                        .{ .err = @errorName(err) },
                    );
                    continue;
                };

                group.async(self.io, sessionWorker, .{
                    self,
                    session,
                    handler,
                    semaphore,
                });
            }
        }

        fn sessionWorker(
            self: *Self,
            session: netz.webtransport.runtime.AcceptedHandshakeSession,
            handler: Handler,
            semaphore: *std.Io.Semaphore,
        ) std.Io.Cancelable!void {
            var owned = session;
            defer {
                owned.deinit();
                semaphore.post(self.io);
            }

            var wrapper = Session{
                .inner = &owned,
                .max_stream_bytes = self.options.max_stream_bytes,
                .max_datagram_bytes = self.options.max_datagram_bytes,
            };
            handler(&self.app, &wrapper) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                logging_mod.logWarn(
                    "weft",
                    "webtransport session failed: {s}",
                    .{@errorName(err)},
                    .{ .err = @errorName(err) },
                );
            };
            owned.drainWithTimeout(.fromMilliseconds(100)) catch {};
            owned.close(0, "") catch {};
        }
    };
}
