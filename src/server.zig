const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const stream_mod = @import("stream.zig");
const dispatch_mod = @import("dispatch.zig");
const drain_mod = @import("drain.zig");

pub const Ctx = ctx_mod.Ctx;
pub const Handler = ctx_mod.Handler;
pub const Response = response_mod.Response;
pub const Limits = limits_mod.Limits;
pub const Router = router_mod.Router;
pub const RouteOptions = router_mod.RouteOptions;

pub const Options = struct {
    address: std.Io.net.IpAddress,
    limits: Limits = .{},
    /// Application middleware that runs before every route, including
    /// `404`, `405`, and automatic `OPTIONS` responses. The slice must outlive
    /// the server and its router.
    middleware: []const Handler = &.{},
    /// Number of connection workers. Each worker owns at most one live
    /// connection at a time, so this is the effective concurrent-connection
    /// bound.
    max_connections: usize = 256,
    max_requests_per_connection: usize = 1000,
    accept_error_backoff: std.Io.Duration = .fromMilliseconds(10),
    /// How often idle workers re-check the shutdown flag while blocked on
    /// accept. This bounds shutdown latency without canceling in-flight work.
    accept_poll_interval: std.Io.Duration = .fromMilliseconds(25),
    /// Optional TLS configuration. When set, the server uses Netz's TLS
    /// transport; `limits` and `tcp_nodelay` from `Limits` override the nested
    /// TLS limits. Certificate-chain, cipher-suite, and identity storage must
    /// outlive the server.
    tls: ?netz.http1.runtime.TlsListenOptions = null,
    /// Accept and TLS-handshake budget used by TLS workers. Netz applies one
    /// deadline to both steps, so this value is also the idle shutdown polling
    /// interval for TLS connections.
    tls_accept_timeout: std.Io.Duration = .fromMilliseconds(500),
    /// Optional budget for workers to drain after `stop`. On expiry the group
    /// is cancelled cooperatively.
    drain_timeout: ?std.Io.Duration = .fromSeconds(5),
};

const Listener = union(enum) {
    plain: netz.http1.runtime.Server,
    tls: netz.http1.runtime.TlsServer,

    fn deinit(self: *Listener) void {
        switch (self.*) {
            .plain => |*server| server.deinit(),
            .tls => |*server| server.deinit(),
        }
    }

    fn address(self: *const Listener) std.Io.net.IpAddress {
        return switch (self.*) {
            .plain => |server| server.address(),
            .tls => |server| server.address(),
        };
    }

    fn acceptWithTimeout(
        self: *Listener,
        timeout: std.Io.Duration,
    ) !netz.http1.runtime.Connection {
        return switch (self.*) {
            .plain => |*server| server.acceptWithTimeout(timeout),
            .tls => |*server| server.acceptWithTimeout(timeout),
        };
    }
};

const StreamState = struct {
    writer: *netz.http1.runtime.ResponseWriter,
    remaining: usize,
};

fn writeWithBudget(raw: ?*anyopaque, data: []const u8) anyerror!void {
    const state: *StreamState = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    if (data.len > state.remaining) return error.ResponseTooLarge;
    state.remaining -= data.len;
    try state.writer.write(data);
}

/// A bounded HTTP/1 application server on top of Netz.
///
/// `H` is the application context passed to route handlers. Handlers are plain
/// `fn (*H, *Ctx) anyerror!void` functions; middleware is
/// `fn (*Ctx) anyerror!void` or a parameterized `Handler` built with
/// `withContext`.
pub fn Server(comptime H: type) type {
    comptime {
        if (H == void) {
            @compileError("weft.Server requires a non-void app context; use an empty struct");
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
                options.accept_poll_interval.nanoseconds <= 0 or
                options.tls_accept_timeout.nanoseconds <= 0 or
                (options.drain_timeout != null and
                    options.drain_timeout.?.nanoseconds <= 0) or
                options.limits.max_head_bytes == 0 or
                options.limits.max_request_headers == 0 or
                options.limits.max_body_bytes == 0 or
                options.limits.max_request_arena_bytes == 0 or
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

            var netz_server: Listener = if (options.tls) |tls_options| blk: {
                var tls = tls_options;
                tls.limits = options.limits.toNetz();
                tls.tcp_nodelay = options.limits.tcp_nodelay;
                break :blk .{ .tls = try netz.http1.runtime.TlsServer.listen(
                    allocator,
                    io,
                    options.address,
                    tls,
                ) };
            } else .{ .plain = try netz.http1.runtime.Server.listen(
                allocator,
                io,
                options.address,
                options.limits.toNetz(),
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

        pub fn address(self: *const @This()) std.Io.net.IpAddress {
            return self.netz_server.address();
        }

        pub fn router(self: *@This()) *router_mod.Router(H) {
            return &self.app_router;
        }

        /// Request shutdown. Idle workers stop accepting promptly, in-flight
        /// requests are allowed to finish, and responses written after the
        /// request carry `Connection: close`.
        pub fn stop(self: *@This()) void {
            self.shutdown.set(self.io);
        }

        /// Serve until `stop` is called or the serving task is cancelled.
        ///
        /// On `stop`, the function waits for workers to finish their current
        /// request before returning. Callers must not `deinit` the server until
        /// `serve` has returned.
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
                    self.options.accept_poll_interval;
                var connection = self.netz_server.acceptWithTimeout(
                    accept_timeout,
                ) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    if (err == error.Timeout) continue;
                    if (self.shutdown.isSet()) return;
                    std.log.scoped(.weft).warn(
                        "accept failed: {s}",
                        .{@errorName(err)},
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
                    std.log.scoped(.weft).warn(
                        "connection error: {s}",
                        .{@errorName(err)},
                    );
                };
            }
        }

        fn serveConnection(
            self: *@This(),
            connection: *netz.http1.runtime.Connection,
        ) !void {
            const arena_buffer = try self.allocator.alloc(
                u8,
                self.options.limits.max_request_arena_bytes,
            );
            defer self.allocator.free(arena_buffer);

            var served: usize = 0;
            while (served < self.options.max_requests_per_connection) : (served += 1) {
                if (self.shutdown.isSet()) return;

                var request = connection.readRequest(.{
                    .max_headers = self.options.limits.max_request_headers,
                    .max_request_target_bytes = self.options.limits.max_request_target_bytes,
                }) catch |err| {
                    if (err == error.ConnectionClosed) return;
                    if (err == error.Canceled) return error.Canceled;
                    const status = statusForReadError(err) orelse return;
                    connection.writeResponse(.{
                        .status = status,
                        .reason = response_mod.reasonFor(status),
                        .headers = &.{.{
                            .name = "Connection",
                            .value = "close",
                        }},
                    }) catch {};
                    return;
                };
                defer request.deinit(self.allocator);

                var fixed_buffer = std.heap.FixedBufferAllocator.init(
                    arena_buffer,
                );
                const arena = fixed_buffer.allocator();

                const client_info = ctx_mod.ClientInfo{
                    .address = connection.stream.socket.address,
                    .protocol = switch (request.request.version) {
                        .http_1_0 => .http_1_0,
                        .http_1_1 => .http_1_1,
                        else => .http_1_1,
                    },
                    .tls = connection.tls_server_conn != null,
                };

                var response = self.dispatch(
                    &request.request,
                    client_info,
                    arena,
                ) catch |err| blk: {
                    if (err == error.Canceled) return error.Canceled;
                    std.log.scoped(.weft).warn(
                        "dispatch failed: {s}",
                        .{@errorName(err)},
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

                const keep_alive = request.request.keepAlive() and
                    !self.shutdown.isSet();
                if (!keep_alive) {
                    response.setHeader("Connection", "close") catch {};
                } else if (request.request.version == .http_1_0) {
                    response.setHeader("Connection", "keep-alive") catch {};
                }
                if (self.shutdown.isSet()) connection.gracefulShutdown();

                if (response.stream) |body| {
                    const body_forbidden = request.request.method == .HEAD or
                        response.status == 204 or
                        response.status == 304 or
                        (response.status >= 100 and response.status < 200);
                    if (body_forbidden) {
                        body.cancel();
                        response.stream = null;
                        if (request.request.method == .HEAD) {
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
                        try connection.writeResponse(response.toOptionsFor(
                            request.request.method,
                            request.request.version,
                        ));
                    } else {
                        try self.writeStreaming(
                            connection,
                            &request.request,
                            &response,
                            body,
                        );
                    }
                } else {
                    try connection.writeResponse(response.toOptionsFor(
                        request.request.method,
                        request.request.version,
                    ));
                }

                if (!keep_alive) return;
            }
        }

        fn writeStreaming(
            self: *@This(),
            connection: *netz.http1.runtime.Connection,
            request: *const netz.http1.Request,
            response: *Response,
            body: stream_mod.Body,
        ) !void {
            if (body.length) |length| {
                if (length > self.options.limits.max_response_bytes) {
                    body.cancel();
                    return error.ResponseTooLarge;
                }
            }

            var writer = connection.startResponse(.{
                .version = request.version,
                .status = response.status,
                .reason = response.reason,
                .headers = response.headers.items,
                .body_length = body.length,
                .request_method = request.method,
            }) catch |err| {
                body.cancel();
                return err;
            };
            defer writer.deinit();

            var state = StreamState{
                .writer = &writer,
                .remaining = body.length orelse
                    self.options.limits.max_response_bytes,
            };
            var stream_writer = stream_mod.Writer{
                .context = &state,
                .write_fn = writeWithBudget,
            };
            try body.run(&stream_writer);
            try writer.finish();
            response.stream = null;
        }

        fn dispatch(
            self: *@This(),
            request: *const netz.http1.Request,
            client_info: ctx_mod.ClientInfo,
            arena: std.mem.Allocator,
        ) !Response {
            return dispatch_mod.dispatch(
                H,
                &self.app,
                &self.app_router,
                self.io,
                self.options.limits,
                self.options.middleware,
                request,
                client_info,
                arena,
            );
        }
    };
}

fn internalErrorResponse(
    arena: std.mem.Allocator,
    limits: Limits,
) Response {
    var response = Response.initWithLimits(arena, limits);
    response.setStatus(500);
    response.text("Internal Server Error") catch {};
    return response;
}

fn statusForReadError(err: anyerror) ?u16 {
    if (err == error.HeadersTooLarge or err == error.TooManyHeaders) {
        return 431;
    }
    if (err == error.UriTooLong) return 414;
    if (err == error.BodyTooLarge) return 413;
    if (err == error.Timeout) return 408;
    if (err == error.MalformedStartLine or
        err == error.MalformedHeader or
        err == error.InvalidMethod or
        err == error.InvalidVersion or
        err == error.InvalidHost or
        err == error.InvalidContentLength or
        err == error.ConflictingContentLength or
        err == error.InvalidTransferEncoding or
        err == error.InvalidConnection or
        err == error.InvalidExpectation or
        err == error.InvalidTrailer or
        err == error.ChunkSizeOverflow or
        err == error.ChunkExtensionTooLarge or
        err == error.ContentLengthOverflow)
    {
        return 400;
    }
    return null;
}
