const std = @import("std");
const netz = @import("netz");
const logging_mod = @import("logging.zig");
const bounded_arena_mod = @import("bounded_arena.zig");
const ctx_mod = @import("ctx.zig");
const handler_mod = @import("handler.zig");
const body_mod = @import("body.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const errors_mod = @import("errors.zig");
const limits_mod = @import("limits.zig");
const dispatch_mod = @import("dispatch.zig");
const stream_mod = @import("stream.zig");
const drain_mod = @import("drain.zig");
const adapter_body = @import("adapter/body.zig");
const adapter_header = @import("adapter/header_view.zig");
const adapter_response = @import("adapter/response.zig");
const adapter_write = @import("adapter/write.zig");
const websocket_mod = @import("websocket.zig");

const Ctx = ctx_mod.Ctx;
const Handler = handler_mod.Handler;
const Response = response_mod.Response;
const Limits = limits_mod.Limits;
const Router = router_mod.Router;
const RouteOptions = router_mod.RouteOptions;

pub const Options = struct {
    /// TCP listen address. Exactly one of `address` and `unix_path` must be
    /// set.
    address: ?std.Io.net.IpAddress = null,
    /// Serve h2c on a Unix domain socket instead of TCP. TLS is not supported
    /// on Unix sockets.
    unix_path: ?[]const u8 = null,
    limits: Limits = .{},
    /// Application middleware that runs for matched routes, `404`, `405`,
    /// `400`, and automatic `OPTIONS`. The slice must outlive the server.
    middleware: []const Handler = &.{},
    not_found: ?Handler = null,
    bad_request: ?Handler = null,
    method_not_allowed: ?Handler = null,
    max_connections: usize = 256,
    max_requests_per_connection: usize = 1000,
    /// Maximum buffered-request handler tasks running concurrently per
    /// connection. Buffered and streaming routes share this bound.
    max_concurrent_handlers: usize = 8,
    /// Poll interval used while handlers are active.
    handler_poll_interval: std.Io.Duration = .fromMilliseconds(5),
    /// Optional cap on handler worker threads per connection. Null keeps one
    /// worker per possible concurrent handler.
    max_handler_threads: ?usize = null,
    accept_error_backoff: std.Io.Duration = .fromMilliseconds(10),
    /// TCP accept plus HTTP/2 bootstrap budget. This is also the idle shutdown
    /// polling interval for workers blocked in accept.
    accept_timeout: std.Io.Duration = .fromMilliseconds(500),
    /// Per-request read budget while a connection is otherwise idle. This also
    /// bounds shutdown latency for a connection waiting for a new stream.
    idle_timeout: std.Io.Duration = .fromSeconds(5),
    /// Optional TLS configuration. Netz's HTTP/2 TLS listener requires ALPN
    /// `h2`; weft overrides nested limits and `tcp_nodelay`.
    tls: ?netz.http2.runtime.TlsListenOptions = null,
    /// Accept HTTP/1.1 `Upgrade: h2c` on the cleartext listener. This mode is
    /// mutually exclusive with prior-knowledge h2c: every accepted connection
    /// must start with an HTTP/1.1 upgrade request. TLS and Unix sockets are
    /// rejected when this is enabled.
    h2c_upgrade: bool = false,
    /// On a TLS listener, also negotiate `http/1.1` via ALPN and serve
    /// buffered HTTP/1.1 requests with the same router and middleware. This
    /// mode uses the generic ALPN listener and supports streaming responses
    /// but not WebSocket upgrades or incremental request bodies.
    alpn_http1: bool = false,
    /// TCP accept plus TLS/HTTP/2 bootstrap budget for TLS workers.
    tls_accept_timeout: std.Io.Duration = .fromMilliseconds(500),
    /// Optional budget for workers to drain after `stop`.
    drain_timeout: ?std.Io.Duration = .fromSeconds(5),
};

const Listener = union(enum) {
    plain: netz.http2.runtime.Server,
    tls: netz.http2.runtime.TlsServer,
    unix: netz.http2.runtime.UnixServer,
    alpn: netz.tls.alpn_server.Server,

    fn deinit(self: *Listener) void {
        switch (self.*) {
            .plain => |*server| server.deinit(),
            .tls => |*server| server.deinit(),
            .unix => |*server| server.deinit(),
            .alpn => |*server| server.deinit(),
        }
    }

    fn address(self: *const Listener) ?std.Io.net.IpAddress {
        return switch (self.*) {
            .plain => |server| server.address(),
            .tls => |server| server.address(),
            .unix => null,
            .alpn => |server| server.address(),
        };
    }

    fn acceptWithTimeout(
        self: *Listener,
        timeout: std.Io.Duration,
    ) !netz.http2.runtime.Connection {
        return switch (self.*) {
            .plain => |*server| server.acceptWithTimeout(timeout),
            .tls => |*server| server.acceptWithTimeout(timeout),
            .unix => |*server| server.acceptWithTimeout(timeout),
            .alpn => error.InvalidOptions,
        };
    }

    fn acceptAlpnWithTimeout(
        self: *Listener,
        timeout: std.Io.Duration,
    ) !netz.tls.alpn_server.Accepted {
        return switch (self.*) {
            .alpn => |*server| server.acceptWithTimeout(timeout),
            else => error.InvalidOptions,
        };
    }

    fn acceptUpgradeWithTimeout(
        self: *Listener,
        timeout: std.Io.Duration,
    ) !netz.http2.runtime.H2cUpgradeRequest {
        return switch (self.*) {
            .plain => |*server| server.acceptUpgradeWithTimeout(timeout),
            else => error.InvalidOptions,
        };
    }
};

const Http2StreamState = struct {
    writer: *netz.http2.runtime.ResponseWriter,
    remaining: usize,
};

fn writeWithBudget(raw: ?*anyopaque, data: []const u8) anyerror!void {
    const state: *Http2StreamState = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    try adapter_write.consume(&state.remaining, data);
    try state.writer.write(data);
}

const WsContext = struct {
    stream: *netz.http2.runtime.Connection.ConcurrentStream,
};

fn wsRead(raw: ?*anyopaque, buffer: []u8) anyerror!usize {
    const context: *WsContext = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    return (try context.stream.nextBody(buffer, null)) orelse 0;
}

fn wsWrite(raw: ?*anyopaque, data: []const u8) anyerror!void {
    const context: *WsContext = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    try context.stream.writeData(data, false);
}

fn wsClose(raw: ?*anyopaque) void {
    const context: *WsContext = @ptrCast(@alignCast(raw orelse return));
    context.stream.finish() catch {};
}

fn headerOffersSubprotocol(
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

const Http1StreamState = struct {
    writer: *netz.http1.runtime.ResponseWriter,
    remaining: usize,
};

fn writeHttp1StreamData(raw: ?*anyopaque, data: []const u8) anyerror!void {
    const state: *Http1StreamState = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    try adapter_write.consume(&state.remaining, data);
    try state.writer.write(data);
}

const Http1EarlyHintsContext = struct {
    connection: *netz.http1.runtime.Connection,
    method: netz.http1.Method,
};

fn sendHttp1EarlyHints(
    raw: ?*anyopaque,
    headers: []const netz.http1.Header,
) anyerror!void {
    const context: *Http1EarlyHintsContext = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    try context.connection.writeResponse(.{
        .status = 103,
        .reason = "Early Hints",
        .headers = headers,
        .request_method = context.method,
    });
}

fn requestAcceptsTrailers(request: *const netz.http1.Request) bool {
    const te = request.header("te") orelse return false;
    var parts = std.mem.splitScalar(u8, te, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, part, " \t"),
            "trailers",
        )) return true;
    }
    return false;
}

fn alpnTlsOptions(
    tls: netz.http2.runtime.TlsListenOptions,
) netz.tls.stream.ServerOptions {
    return .{
        .identity = tls.identity,
        .cipher_suites = tls.cipher_suites,
        .tls12_cipher_suites = tls.tls12_cipher_suites,
        .protocol_policy = tls.protocol_policy,
        .max_client_hello_size = tls.max_client_hello_size,
        .max_client_handshake_size = tls.max_client_handshake_size,
        .handshake_timeout = tls.tls_handshake_timeout,
        .client_auth = tls.client_auth,
        .tls13_session_tickets = tls.tls13_session_tickets,
        .tls12_session_tickets = tls.tls12_session_tickets,
        .alpn_protocols = &.{ "h2", "http/1.1" },
        .require_alpn = true,
    };
}

/// A bounded HTTP/2 cleartext server adapter.
///
/// Routes, middleware, request locals, and response budgets are identical to
/// the HTTP/1 adapter. HTTP/2 streams are multiplexed by Netz; each worker
/// owns one connection, runs buffered requests in bounded handler tasks, and
/// submits completed responses serially.
pub fn Http2Server(comptime H: type) type {
    comptime {
        if (H == void) {
            @compileError("weft.Http2Server requires a non-void app context; use an empty struct");
        }
    }
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        app: H,
        options: Options,
        netz_server: Listener,
        app_router: router_mod.Router(H),
        shutdown: std.Io.Event = .unset,

        pub fn init(
            io: std.Io,
            allocator: std.mem.Allocator,
            options: Options,
            app: H,
        ) !@This() {
            if (options.max_connections == 0 or
                options.max_requests_per_connection == 0 or
                options.max_concurrent_handlers == 0 or
                options.max_concurrent_handlers > std.math.maxInt(u32) or
                (options.max_handler_threads != null and
                    options.max_handler_threads.? == 0) or
                options.handler_poll_interval.nanoseconds <= 0 or
                options.accept_error_backoff.nanoseconds <= 0 or
                options.accept_timeout.nanoseconds <= 0 or
                options.idle_timeout.nanoseconds <= 0 or
                options.tls_accept_timeout.nanoseconds <= 0 or
                (options.drain_timeout != null and
                    options.drain_timeout.?.nanoseconds <= 0) or
                (options.limits.request_timeout != null and
                    options.limits.request_timeout.?.nanoseconds <= 0) or
                (options.limits.request_head_timeout != null and
                    options.limits.request_head_timeout.?.nanoseconds <= 0) or
                options.limits.max_head_bytes == 0 or
                options.limits.max_request_target_bytes == 0 or
                options.limits.max_request_headers == 0 or
                options.limits.max_body_bytes == 0 or
                options.limits.max_request_arena_bytes == 0 or
                options.limits.max_streaming_window_bytes == 0 or
                (options.limits.max_http2_concurrent_streams != null and
                    options.limits.max_http2_concurrent_streams.? == 0) or
                options.limits.max_http2_frame_payload == 0 or
                options.limits.max_response_bytes == 0 or
                options.limits.max_response_headers <
                    response_mod.head_fields_overhead + 1 or
                options.limits.max_response_head_bytes <
                    response_mod.head_bytes_overhead + 128 or
                options.limits.max_middleware == 0)
            {
                return error.InvalidOptions;
            }
            if (options.middleware.len > options.limits.max_middleware) {
                return error.TooMuchMiddleware;
            }
            const has_tcp = options.address != null;
            const has_unix = options.unix_path != null;
            if (has_tcp == has_unix) return error.InvalidOptions;
            if (has_unix and options.tls != null) return error.InvalidOptions;
            if (options.h2c_upgrade and
                (options.tls != null or options.unix_path != null))
            {
                return error.InvalidOptions;
            }
            if (options.alpn_http1 and
                (options.tls == null or options.unix_path != null or
                    options.h2c_upgrade))
            {
                return error.InvalidOptions;
            }
            const unix_address = if (options.unix_path) |path|
                try std.Io.net.UnixAddress.init(path)
            else
                null;

            var netz_limits = options.limits.toHttp2Netz();
            netz_limits.max_concurrent_streams = @intCast(@min(
                options.limits.max_http2_concurrent_streams orelse
                    options.max_concurrent_handlers,
                options.max_concurrent_handlers,
            ));
            var netz_server: Listener = if (unix_address) |unix| .{ .unix = try netz.http2.runtime.UnixServer.listen(
                allocator,
                io,
                unix,
                netz_limits,
            ) } else if (options.alpn_http1) blk: {
                break :blk .{ .alpn = try netz.tls.alpn_server.Server.listen(
                    allocator,
                    io,
                    .{
                        .address = options.address.?,
                        .tls = alpnTlsOptions(options.tls.?),
                        .tcp_nodelay = options.limits.tcp_nodelay,
                    },
                ) };
            } else if (options.tls) |tls_options| blk: {
                var tls = tls_options;
                tls.limits = netz_limits;
                tls.tcp_nodelay = options.limits.tcp_nodelay;
                break :blk .{ .tls = try netz.http2.runtime.TlsServer.listen(
                    allocator,
                    io,
                    options.address.?,
                    tls,
                ) };
            } else .{ .plain = try netz.http2.runtime.Server.listen(
                allocator,
                io,
                options.address.?,
                netz_limits,
            ) };
            errdefer netz_server.deinit();

            return .{
                .io = io,
                .allocator = allocator,
                .app = app,
                .options = options,
                .netz_server = netz_server,
                .app_router = router_mod.Router(H).initWithMaxMiddleware(
                    allocator,
                    options.limits.max_middleware,
                ),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.app_router.deinit();
            self.netz_server.deinit();
            self.* = undefined;
        }

        /// TCP listen address. Panics for a Unix-socket server; use
        /// `ipAddress()` or `unixPath()` when the transport is not known.
        pub fn address(self: *const @This()) std.Io.net.IpAddress {
            return self.netz_server.address() orelse
                @panic("Unix-socket server has no TCP address");
        }

        /// TCP listen address, or null for a Unix-socket server.
        pub fn ipAddress(self: *const @This()) ?std.Io.net.IpAddress {
            return self.netz_server.address();
        }

        /// Configured Unix socket path, or null for a TCP server.
        pub fn unixPath(self: *const @This()) ?[]const u8 {
            return self.options.unix_path;
        }

        pub fn router(self: *@This()) *router_mod.Router(H) {
            return &self.app_router;
        }

        pub fn stop(self: *@This()) void {
            self.shutdown.set(self.io);
        }

        pub fn serve(self: *@This()) !void {
            var group: std.Io.Group = .init;
            var group_finished = false;
            defer if (!group_finished) group.cancel(self.io);

            for (0..self.options.max_connections) |_| {
                try group.concurrent(self.io, worker, .{self});
            }

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

        fn worker(self: *@This()) std.Io.Cancelable!void {
            while (true) {
                if (self.shutdown.isSet()) return;

                const accept_timeout = if (self.options.tls != null)
                    self.options.tls_accept_timeout
                else
                    self.options.accept_timeout;
                if (self.options.alpn_http1) {
                    const accepted = self.netz_server.acceptAlpnWithTimeout(
                        accept_timeout,
                    ) catch |err| {
                        if (err == error.Canceled) return error.Canceled;
                        if (err == error.Timeout) continue;
                        if (self.shutdown.isSet()) return;
                        logging_mod.logWarn(
                            "weft",
                            "http2 ALPN accept failed: {s}",
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
                    self.serveAlpnConnection(accepted) catch |err| {
                        if (err == error.Canceled) return error.Canceled;
                        logging_mod.logWarn(
                            "weft",
                            "http2 ALPN connection error: {s}",
                            .{@errorName(err)},
                            .{ .err = @errorName(err) },
                        );
                    };
                    continue;
                }

                if (self.options.h2c_upgrade) {
                    var upgrade = self.netz_server.acceptUpgradeWithTimeout(
                        accept_timeout,
                    ) catch |err| {
                        if (err == error.Canceled) return error.Canceled;
                        if (err == error.Timeout) continue;
                        if (self.shutdown.isSet()) return;
                        logging_mod.logWarn(
                            "weft",
                            "http2 h2c upgrade failed: {s}",
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
                    defer upgrade.deinit(self.allocator);
                    self.serveUpgrade(&upgrade) catch |err| {
                        if (err == error.Canceled) return error.Canceled;
                        logging_mod.logWarn(
                            "weft",
                            "http2 h2c upgrade error: {s}",
                            .{@errorName(err)},
                            .{ .err = @errorName(err) },
                        );
                    };
                    continue;
                }

                var connection = self.netz_server.acceptWithTimeout(
                    accept_timeout,
                ) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    if (err == error.Timeout) continue;
                    if (self.shutdown.isSet()) return;
                    logging_mod.logWarn(
                        "weft",
                        "http2 accept failed: {s}",
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
                defer connection.close();

                self.serveConnection(&connection) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    logging_mod.logWarn(
                        "weft",
                        "http2 connection error: {s}",
                        .{@errorName(err)},
                        .{ .err = @errorName(err) },
                    );
                };
            }
        }

        const ConcurrentStream = netz.http2.runtime.Connection.ConcurrentStream;

        fn serveConnection(
            self: *@This(),
            connection: *netz.http2.runtime.Connection,
        ) !void {
            const effective = @max(
                1,
                @min(
                    self.options.limits.max_http2_concurrent_streams orelse
                        self.options.max_concurrent_handlers,
                    self.options.max_concurrent_handlers,
                ),
            );
            var context = H2ConcurrentContext(H){
                .server = self,
                // std reports a synthetic loopback address for Unix sockets,
                // so do not expose it as a real peer.
                .address = switch (self.netz_server) {
                    .unix => null,
                    else => connection.stream.socket.address,
                },
                .peer_certificates = connection.peerCertificates() orelse &.{},
                .max_requests = self.options.max_requests_per_connection,
            };
            var watcher = self.io.async(
                H2ShutdownWatch.run,
                .{ self.io, &self.shutdown, &context.session_shutdown },
            );
            defer {
                context.session_shutdown.set(self.io);
                _ = watcher.cancel(self.io);
            }

            _ = connection.serveConcurrentStreams(
                H2ConcurrentContext(H),
                &context,
                handleConcurrentStream,
                .{
                    .max_streams = effective,
                    .idle_timeout = self.options.idle_timeout,
                    .shutdown = &context.session_shutdown,
                    .poll_interval = self.options.handler_poll_interval,
                    .max_worker_threads = self.options.max_handler_threads,
                    .inline_bodyless = self.app_router.hasInlineBodylessRoutes(),
                },
            ) catch |err| {
                if (err == error.Canceled) return err;
                // Idle connections close through `idle_timeout`; that is a
                // normal lifecycle event, not a connection failure.
                if (err == error.Timeout) return;
                logging_mod.logWarn(
                    "weft",
                    "http2 serve failed: {s}",
                    .{@errorName(err)},
                    .{ .err = @errorName(err) },
                );
                return err;
            };
        }

        fn serveAlpnConnection(
            self: *@This(),
            accepted: netz.tls.alpn_server.Accepted,
        ) !void {
            var tls_owned = true;
            var stream_owned = true;
            errdefer if (tls_owned) accepted.tls.deinit();
            errdefer if (stream_owned) accepted.stream.close(self.io);

            const alpn = accepted.tls.selected_alpn orelse
                return error.InvalidAlpn;
            if (std.mem.eql(u8, alpn, "h2")) {
                var connection = try netz.http2.runtime.adoptNegotiatedTlsServer(
                    self.allocator,
                    self.io,
                    accepted.stream,
                    accepted.tls,
                    self.options.limits.toHttp2Netz(),
                );
                tls_owned = false;
                stream_owned = false;
                defer connection.close();
                try self.serveConnection(&connection);
                return;
            }
            if (std.mem.eql(u8, alpn, "http/1.1")) {
                var connection = netz.http1.runtime.Connection{
                    .io = self.io,
                    .allocator = self.allocator,
                    .stream = accepted.stream,
                    .limits = self.options.limits.toNetz(),
                    .tls_server_conn = accepted.tls,
                };
                tls_owned = false;
                stream_owned = false;
                defer connection.close();
                try self.serveHttp1Connection(&connection);
                return;
            }
            return error.InvalidAlpn;
        }

        fn serveHttp1Connection(
            self: *@This(),
            connection: *netz.http1.runtime.Connection,
        ) !void {
            var request_count: usize = 0;
            while (request_count < self.options.max_requests_per_connection) : (request_count += 1) {
                var owned = connection.readRequest(.{}) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    return;
                };
                defer owned.deinit(self.allocator);
                const request = &owned.request;

                var arena_state = std.heap.ArenaAllocator.init(self.allocator);
                defer arena_state.deinit();
                const arena = arena_state.allocator();

                const client_info = handler_mod.ClientInfo{
                    .address = handler_mod.resolveClientAddress(
                        request.headers,
                        connection.stream.socket.address,
                        self.options.limits.trust_forwarded_for,
                    ),
                    .peer_certificates = connection.peerCertificates() orelse &.{},
                    .protocol = .http_1_1,
                    .tls = connection.tls_server_conn != null,
                };
                var prepared: router_mod.Prepared = undefined;
                dispatch_mod.prepareRoute(
                    H,
                    &self.app_router,
                    request.method,
                    request.target,
                    &prepared,
                );
                var early_hints_context = Http1EarlyHintsContext{
                    .connection = connection,
                    .method = request.method,
                };
                var response = self.dispatchRequest(
                    request,
                    client_info,
                    arena,
                    null,
                    &prepared,
                    .{
                        .context = &early_hints_context,
                        .send_fn = sendHttp1EarlyHints,
                    },
                ) catch |err| blk: {
                    if (err == error.Canceled) return err;
                    logging_mod.logWarn(
                        "weft",
                        "http2 ALPN http/1.1 dispatch failed: {s}",
                        .{@errorName(err)},
                        .{ .err = @errorName(err) },
                    );
                    break :blk internalErrorResponse(
                        arena,
                        self.options.limits,
                    );
                };

                if (response.body.len > self.options.limits.max_response_bytes) {
                    response.reset();
                    response.setStatus(500);
                    response.text("Response Too Large") catch {};
                }
                response.validateHead() catch {
                    response.reset();
                    response.setStatus(500);
                    response.text("Internal Server Error") catch {};
                };

                if (response.stream) |body| {
                    try self.writeHttp1Stream(
                        connection,
                        request,
                        &response,
                        body,
                        arena,
                    );
                    response.stream = null;
                } else {
                    try connection.writeResponse(.{
                        .status = response.status,
                        .reason = response.reason,
                        .headers = response.headers.items,
                        .body = response.body,
                        .trailers = response.trailers.items,
                        .request_accepts_trailers = requestAcceptsTrailers(request),
                        .request_method = request.method,
                    });
                }

                if (request.must_close or !request.keepAlive()) return;
            }
        }

        fn writeHttp1Stream(
            self: *@This(),
            connection: *netz.http1.runtime.Connection,
            request: *const netz.http1.Request,
            response: *Response,
            body: stream_mod.Body,
            arena: std.mem.Allocator,
        ) !void {
            var trailer_names = std.ArrayListUnmanaged([]const u8).empty;
            for (response.trailers.items) |header| {
                try trailer_names.append(arena, header.name);
            }
            const accepts_trailers = requestAcceptsTrailers(request);
            var writer = connection.startResponse(.{
                .status = response.status,
                .reason = response.reason,
                .headers = response.headers.items,
                .body_length = body.length,
                .trailer_names = trailer_names.items,
                .request_accepts_trailers = accepts_trailers,
                .request_method = request.method,
            }) catch |err| {
                body.cancel();
                return err;
            };
            defer writer.deinit();

            var state = Http1StreamState{
                .writer = &writer,
                .remaining = body.length orelse
                    self.options.limits.max_response_bytes,
            };
            var stream_writer = stream_mod.Writer{
                .context = &state,
                .write_fn = writeHttp1StreamData,
            };
            try body.run(&stream_writer);
            if (response.trailers.items.len != 0 and accepts_trailers) {
                try writer.finishTrailers(response.trailers.items);
            } else {
                try writer.finish();
            }
        }

        fn serveUpgrade(
            self: *@This(),
            upgrade: *netz.http2.runtime.H2cUpgradeRequest,
        ) !void {
            const request = &upgrade.request.request;
            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const client_info = handler_mod.ClientInfo{
                .address = handler_mod.resolveClientAddress(
                    request.headers,
                    upgrade.connection.stream.socket.address,
                    self.options.limits.trust_forwarded_for,
                ),
                .peer_certificates = &.{},
                .protocol = .http_2,
                .tls = false,
            };
            var prepared: router_mod.Prepared = undefined;
            dispatch_mod.prepareRoute(
                H,
                &self.app_router,
                request.method,
                request.target,
                &prepared,
            );
            var response = self.dispatchRequest(
                request,
                client_info,
                arena,
                null,
                &prepared,
                .{},
            ) catch |err| blk: {
                if (err == error.Canceled) return err;
                logging_mod.logWarn(
                    "weft",
                    "http2 h2c upgrade dispatch failed: {s}",
                    .{@errorName(err)},
                    .{ .err = @errorName(err) },
                );
                break :blk internalErrorResponse(
                    arena,
                    self.options.limits,
                );
            };

            if (response.stream) |body| {
                body.cancel();
                response.stream = null;
                response.reset();
                response.setStatus(500);
                response.text(
                    "Streaming responses are not supported for the h2c upgrade request",
                ) catch {};
            }
            if (response.body.len > self.options.limits.max_response_bytes) {
                response.reset();
                response.setStatus(500);
                response.text("Response Too Large") catch {};
            }
            response.validateHead() catch {
                response.reset();
                response.setStatus(500);
                response.text("Internal Server Error") catch {};
            };

            const headers = try headerFields(&response, arena);
            const trailers = try trailerFields(&response, arena);
            try upgrade.connection.writeResponse(
                upgrade.stream_id,
                .{
                    .status = response.status,
                    .headers = headers,
                    .body = response.body,
                    .trailers = trailers,
                    .request_method = request.method.string(),
                },
            );

            try self.serveConnection(&upgrade.connection);
        }

        fn handleConcurrentStream(
            context: *H2ConcurrentContext(H),
            stream: *ConcurrentStream,
        ) anyerror!void {
            try context.server.serveConcurrentStream(
                stream,
                context.address,
                context.peer_certificates,
            );
            const completed = context.completed.fetchAdd(1, .monotonic) + 1;
            if (completed >= context.max_requests) {
                context.session_shutdown.set(context.server.io);
            }
        }

        fn serveConcurrentStream(
            self: *@This(),
            stream: *ConcurrentStream,
            peer_address: ?std.Io.net.IpAddress,
            peer_certificates: []const []const u8,
        ) !void {
            var bounded_arena = bounded_arena_mod.BoundedArena.init(
                self.allocator,
                self.options.limits.max_request_arena_bytes,
            );
            defer bounded_arena.deinit();
            const arena = bounded_arena.allocator();

            const head = stream.head();
            const method = netz.http1.Method.parse(head.method) catch {
                stream.reset(.protocol_error) catch {};
                return;
            };
            const target = if (head.path.len == 0) "/" else head.path;
            const websocket_upgrade = method == .CONNECT and
                head.protocol != null and
                std.mem.eql(u8, head.protocol.?, "websocket");

            // Route matching uses the path, never the query string carried by
            // the `:path` pseudo-header. The result is reused by dispatch;
            // `prepareRoute` resets the counts before any read.
            var prepared: router_mod.Prepared = undefined;
            dispatch_mod.prepareRoute(
                H,
                &self.app_router,
                if (websocket_upgrade) .GET else method,
                target,
                &prepared,
            );

            // Inline handlers run on the connection owner. Decline before any
            // side effect when the route did not opt in, needs a streaming
            // request body, or hits a rejection path.
            if (stream.isInline()) {
                const route = prepared.route orelse
                    return error.InlineDeclined;
                if (method == .CONNECT or
                    websocket_upgrade or
                    !route.inline_bodyless or
                    route.streaming or
                    target.len > self.options.limits.max_request_target_bytes)
                {
                    return error.InlineDeclined;
                }
            }

            // Non-WebSocket CONNECT tunnels are not exposed by weft.
            if (method == .CONNECT and !websocket_upgrade) {
                return self.rejectConcurrent(
                    stream,
                    head.method,
                    501,
                    "Not Implemented",
                    arena,
                );
            }
            if (target.len > self.options.limits.max_request_target_bytes) {
                return self.rejectConcurrent(
                    stream,
                    head.method,
                    414,
                    "URI Too Long",
                    arena,
                );
            }
            // Common requests fit a stack header view, so the request arena
            // stays untouched until the handler or response actually needs it.
            var header_stack: [32]netz.http1.Header = undefined;
            const headers = convertH2HeadersInto(
                header_stack[0..],
                head.headers,
                head.authority,
            ) orelse (convertH2Headers(
                arena,
                head.headers,
                head.authority,
            ) catch {
                stream.reset(.internal_error) catch {};
                return;
            });

            // The concurrent engine only publishes body completion while it is
            // draining a stream, so a request with no DATA frames cannot be
            // read to completion from the handler. Use the declared length to
            // avoid waiting for a body that cannot arrive, and keep the
            // streaming reader for routes that opted in or for unknown-length
            // bodies.
            const route_streaming = if (prepared.route) |route|
                route.streaming
            else
                false;
            const declared_length = head.content_length;
            const has_declared_body = declared_length != null and
                declared_length.? != 0;
            const streaming = if (websocket_upgrade)
                false
            else
                route_streaming or declared_length == null;
            var body: []const u8 = "";
            var trailers: []netz.http1.Header = &.{};
            var h2_reader: body_mod.H2StreamReader = undefined;
            var reader: ?body_mod.BodyReader = null;
            if (streaming) {
                h2_reader = body_mod.H2StreamReader.init(
                    stream,
                    self.options.limits.max_streaming_window_bytes,
                );
                reader = .{ .h2_stream = &h2_reader };
            } else if (has_declared_body) {
                body = readWholeBody(
                    arena,
                    self.allocator,
                    stream,
                    declared_length,
                    self.options.limits.max_body_bytes,
                    self.options.limits.max_request_arena_bytes,
                ) catch |err| {
                    if (err == error.Canceled) return err;
                    var response = Response.initWithLimits(
                        arena,
                        self.options.limits,
                    );
                    if (err == error.PayloadTooLarge) {
                        response.setStatus(413);
                        response.text("Payload Too Large") catch {};
                    } else {
                        response.setStatus(500);
                        response.text("Internal Server Error") catch {};
                    }
                    try self.respondConcurrent(
                        stream,
                        head.method,
                        &response,
                        arena,
                    );
                    return;
                };
                if (stream.trailers()) |fields| {
                    trailers = convertH2Trailers(arena, fields) catch &.{};
                }
            } else if (stream.trailers()) |fields| {
                // Declared zero length: the request has no body to buffer.
                trailers = convertH2Trailers(arena, fields) catch &.{};
            }

            var request = netz.http1.Request{
                .method = if (websocket_upgrade) .GET else method,
                .target = target,
                .version = .http_1_1,
                .headers = headers,
                .body = body,
                .trailers = trailers,
                .consumed = 0,
                .must_close = false,
            };
            const client_info = handler_mod.ClientInfo{
                .address = handler_mod.resolveClientAddress(
                    head.headers,
                    peer_address,
                    self.options.limits.trust_forwarded_for,
                ),
                .peer_certificates = peer_certificates,
                .protocol = .http_2,
                .tls = self.options.tls != null,
            };
            var early_hints_context = EarlyHintsContext{
                .connection = stream.engine.connection,
                .stream_id = stream.streamId(),
                .arena = arena,
            };
            var response = self.dispatchRequest(
                &request,
                client_info,
                arena,
                reader,
                &prepared,
                .{
                    .context = &early_hints_context,
                    .send_fn = sendEarlyHints,
                },
            ) catch |err| blk: {
                if (err == error.Canceled) return err;
                logging_mod.logWarn(
                    "weft",
                    "http2 dispatch failed: {s}",
                    .{@errorName(err)},
                    .{ .err = @errorName(err) },
                );
                break :blk internalErrorResponse(
                    arena,
                    self.options.limits,
                );
            };

            if (response.body.len > self.options.limits.max_response_bytes) {
                response.reset();
                response.setStatus(500);
                response.text("Response Too Large") catch {};
            }
            response.validateHead() catch {
                response.reset();
                response.setStatus(500);
                response.text("Internal Server Error") catch {};
            };

            if (websocket_upgrade and response.upgrade != null) {
                try self.runWebSocket(
                    stream,
                    head,
                    &request,
                    &response,
                    arena,
                );
                return;
            }

            self.respondConcurrent(
                stream,
                head.method,
                &response,
                arena,
            ) catch |err| {
                if (err == error.Canceled) return err;
                if (errors_mod.isPeerDisconnect(err)) {
                    logging_mod.logDebug(
                        "weft",
                        "http2 response failed: {s}",
                        .{@errorName(err)},
                        .{ .err = @errorName(err) },
                    );
                } else {
                    logging_mod.logWarn(
                        "weft",
                        "http2 response failed: {s}",
                        .{@errorName(err)},
                        .{ .err = @errorName(err) },
                    );
                }
                stream.reset(.internal_error) catch {};
            };
        }

        /// Answer a request that exceeded an adapter budget without running
        /// the router.
        fn runWebSocket(
            self: *@This(),
            stream: *ConcurrentStream,
            head: anytype,
            request: *const netz.http1.Request,
            response: *Response,
            arena: std.mem.Allocator,
        ) !void {
            const upgrade = response.upgrade.?;
            const version = request.header("sec-websocket-version") orelse "";
            if (!std.mem.eql(u8, version, "13")) {
                return self.rejectConcurrent(
                    stream,
                    head.method,
                    426,
                    "Upgrade Required",
                    arena,
                );
            }
            if (upgrade.subprotocol) |sub| {
                if (!netz.websocket.validSubprotocolToken(sub) or
                    !headerOffersSubprotocol(request, sub))
                {
                    return self.rejectConcurrent(
                        stream,
                        head.method,
                        400,
                        "Bad Request",
                        arena,
                    );
                }
            }

            var fields = std.ArrayListUnmanaged(netz.http2.Hpack.HeaderField).empty;
            if (upgrade.subprotocol) |sub| {
                try fields.append(arena, .{
                    .name = "sec-websocket-protocol",
                    .value = sub,
                });
            }
            try stream.startResponse(.{
                .status = 200,
                .headers = fields.items,
                .request_method = "CONNECT",
                .extended_connect = true,
            });

            var ws_context = WsContext{ .stream = stream };
            const connection = netz.websocket.stream_connection.Connection.init(
                self.allocator,
                self.io,
                .{
                    .context = &ws_context,
                    .read_fn = wsRead,
                    .write_fn = wsWrite,
                },
                .{
                    .role = .server,
                    .max_message_bytes = self.options.limits.max_body_bytes,
                    .max_frame_bytes = self.options.limits.max_response_bytes,
                },
            );
            var session = websocket_mod.Session{
                .inner = .{ .stream = connection },
            };
            defer session.close();
            try upgrade.run(&session);
        }

        fn rejectConcurrent(
            self: *@This(),
            stream: *ConcurrentStream,
            method: []const u8,
            status: u16,
            message: []const u8,
            arena: std.mem.Allocator,
        ) !void {
            var response = Response.initWithLimits(arena, self.options.limits);
            response.setStatus(status);
            response.text(message) catch {};
            return self.respondConcurrent(stream, method, &response, arena);
        }

        fn respondConcurrent(
            self: *@This(),
            stream: *ConcurrentStream,
            method: []const u8,
            response: *Response,
            arena: std.mem.Allocator,
        ) !void {
            if (stream.isInline() and response.stream != null) {
                response.stream.?.cancel();
                response.stream = null;
                return error.InlineStreamingUnsupported;
            }
            if (response.upgrade != null) {
                response.reset();
                response.setStatus(400);
                response.text(
                    "WebSocket upgrade requires HTTP/1.1",
                ) catch {};
            }

            const body_forbidden = std.mem.eql(u8, method, "HEAD") or
                response.status == 204 or
                response.status == 304 or
                (response.status >= 100 and response.status < 200);

            if (response.stream) |body| {
                if (body_forbidden) {
                    if (std.mem.eql(u8, method, "HEAD")) {
                        if (body.length) |length| {
                            response.setHeader(
                                "Content-Length",
                                try std.fmt.allocPrint(
                                    arena,
                                    "{d}",
                                    .{length},
                                ),
                            ) catch {};
                        }
                    }
                    body.cancel();
                    response.stream = null;
                } else if (body.length) |length| {
                    if (length > self.options.limits.max_response_bytes) {
                        body.cancel();
                        return error.ResponseTooLarge;
                    }
                    response.setHeader(
                        "Content-Length",
                        try std.fmt.allocPrint(arena, "{d}", .{length}),
                    ) catch {};
                }
            } else if (body_forbidden and
                std.mem.eql(u8, method, "HEAD") and
                response.body.len != 0 and
                !response.hasHeader("content-length"))
            {
                // A HEAD response carries the representation length even
                // though its body is suppressed.
                response.setHeader(
                    "Content-Length",
                    try std.fmt.allocPrint(
                        arena,
                        "{d}",
                        .{response.body.len},
                    ),
                ) catch {};
            }

            const options = netz.http2.runtime.StreamingResponseOptions{
                .status = response.status,
                .headers = try headerFields(response, arena),
                .request_method = method,
            };

            // Netz ends the stream in the response head for HEAD/204/304, so
            // any DATA or finish command here would target a finished stream.
            if (body_forbidden) {
                try stream.startResponse(options);
                return;
            }

            if (response.stream) |body| {
                try stream.startResponse(options);
                var state = H2ConcurrentWriterState{
                    .stream = stream,
                    .remaining = body.length orelse
                        self.options.limits.max_response_bytes,
                };
                var writer = stream_mod.Writer{
                    .context = &state,
                    .write_fn = writeConcurrentWithBudget,
                };
                body.run(&writer) catch |err| {
                    body.cancel();
                    stream.reset(.internal_error) catch {};
                    return err;
                };
                if (response.trailers.items.len != 0) {
                    try stream.finishWithTrailers(
                        try trailerFields(response, arena),
                    );
                } else {
                    try stream.finish();
                }
                response.stream = null;
                return;
            }

            // Head and the buffered body share one owner turn; a sequential
            // request would otherwise pay two command round trips.
            if (response.trailers.items.len != 0) {
                if (response.body.len == 0) {
                    try stream.startResponse(options);
                } else {
                    try stream.startResponseWithBody(
                        options,
                        response.body,
                        false,
                    );
                }
                try stream.finishWithTrailers(
                    try trailerFields(response, arena),
                );
            } else {
                try stream.startResponseWithBody(
                    options,
                    response.body,
                    true,
                );
            }
        }

        fn dispatchRequest(
            self: *@This(),
            request: *const netz.http1.Request,
            client_info: handler_mod.ClientInfo,
            arena: std.mem.Allocator,
            body_reader: ?body_mod.BodyReader,
            prepared: *const router_mod.Prepared,
            early_hints: dispatch_mod.EarlyHints,
        ) !Response {
            return dispatch_mod.dispatch(
                H,
                &self.app,
                &self.app_router,
                self.io,
                self.options.limits,
                self.options.middleware,
                .{
                    .not_found = self.options.not_found,
                    .bad_request = self.options.bad_request,
                    .method_not_allowed = self.options.method_not_allowed,
                },
                request,
                client_info,
                arena,
                self.allocator,
                body_reader,
                prepared,
                early_hints,
            );
        }
    };
}

fn H2ConcurrentContext(comptime H: type) type {
    return struct {
        server: *Http2Server(H),
        address: ?std.Io.net.IpAddress = null,
        peer_certificates: []const []const u8 = &.{},
        session_shutdown: std.Io.Event = .unset,
        completed: std.atomic.Value(usize) = .init(0),
        max_requests: usize = 0,
    };
}

const H2ShutdownWatch = struct {
    fn run(
        io: std.Io,
        source: *std.Io.Event,
        target: *std.Io.Event,
    ) void {
        source.wait(io) catch return;
        target.set(io);
    }
};

const H2ConcurrentWriterState = struct {
    stream: *netz.http2.runtime.Connection.ConcurrentStream,
    remaining: usize,
};

fn writeConcurrentWithBudget(
    raw: ?*anyopaque,
    data: []const u8,
) anyerror!void {
    const state: *H2ConcurrentWriterState = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    try adapter_write.consume(&state.remaining, data);
    try state.stream.writeData(data, false);
}

const HeaderView = adapter_header.HeaderView(netz.http2.Hpack.HeaderField);

const EarlyHintsContext = struct {
    connection: *netz.http2.runtime.Connection,
    stream_id: u31,
    arena: std.mem.Allocator,
};

fn sendEarlyHints(
    raw: ?*anyopaque,
    headers: []const netz.http1.Header,
) anyerror!void {
    const context: *EarlyHintsContext = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    const fields = try HeaderView.informationalFields(
        context.arena,
        headers,
    );
    try context.connection.writeInformationalResponse(
        context.stream_id,
        103,
        fields,
    );
}
const readWholeBody = adapter_body.readWholeBody;
const convertH2Trailers = HeaderView.convertTrailers;
const convertH2HeadersInto = HeaderView.convertHeadersInto;
const convertH2Headers = HeaderView.convertHeaders;
const trailerFields = HeaderView.trailerFields;
const headerFields = HeaderView.headerFields;
const lowerHeaderName = HeaderView.lowerHeaderName;
const forbiddenResponseHeader = HeaderView.forbiddenResponseHeader;
const isPseudoHeader = HeaderView.isPseudoHeader;
const findHeader = HeaderView.findHeader;
const internalErrorResponse = adapter_response.internalErrorResponse;

test "h2 request trailers convert to the http1 header view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fields = [_]netz.http2.Hpack.HeaderField{
        .{ .name = "x-checksum", .value = "abc" },
        .{ .name = "x-trace", .value = "one" },
    };
    const headers = try convertH2Trailers(arena.allocator(), &fields);
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("x-checksum", headers[0].name);
    try std.testing.expectEqualStrings("abc", headers[0].value);
    try std.testing.expectEqualStrings("one", headers[1].value);
}
