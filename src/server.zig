const std = @import("std");
const netz = @import("netz");
const body_stream_mod = @import("body_stream.zig");
const ctx_mod = @import("ctx.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const stream_mod = @import("stream.zig");
const dispatch_mod = @import("dispatch.zig");
const drain_mod = @import("drain.zig");
const websocket_mod = @import("websocket.zig");

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
    /// Optional handlers for requests that do not reach a route. They may
    /// inspect `ctx.get(weft.RouteFailure)`; default status and `Allow` fields
    /// are pre-set before they run.
    not_found: ?Handler = null,
    bad_request: ?Handler = null,
    method_not_allowed: ?Handler = null,
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
                options.limits.max_streaming_window_bytes == 0 or
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
                var close_connection = true;
                defer if (close_connection) connection.close();

                const upgraded = self.serveConnection(&connection) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    std.log.scoped(.weft).warn(
                        "connection error: {s}",
                        .{@errorName(err)},
                    );
                    continue;
                };
                if (upgraded) close_connection = false;
            }
        }

        fn serveConnection(
            self: *@This(),
            connection: *netz.http1.runtime.Connection,
        ) !bool {
            const arena_buffer = try self.allocator.alloc(
                u8,
                self.options.limits.max_request_arena_bytes,
            );
            defer self.allocator.free(arena_buffer);

            var served: usize = 0;
            while (served < self.options.max_requests_per_connection) : (served += 1) {
                if (self.shutdown.isSet()) return false;

                var fixed_buffer = std.heap.FixedBufferAllocator.init(
                    arena_buffer,
                );
                const arena = fixed_buffer.allocator();

                var state = StreamingRead(H){
                    .server = self,
                    .allocator = self.allocator,
                    .arena = arena,
                    .client_info = .{
                        .address = connection.stream.socket.address,
                        .protocol = .http_1_1,
                        .tls = connection.tls_server_conn != null,
                    },
                };
                defer state.body.deinit(self.allocator);
                defer state.clearStreaming();

                var request = connection.readRequestStreamingWithOptionsAndHead(
                    .{
                        .max_headers = self.options.limits.max_request_headers,
                        .max_request_target_bytes = self.options.limits.max_request_target_bytes,
                    },
                    &state,
                    StreamingRead(H).onHead,
                    StreamingRead(H).onChunk,
                ) catch |err| {
                    if (state.streaming) {
                        state.reader.?.finish();
                        if (state.future) |*future| {
                            _ = future.await(self.io) catch {};
                        }
                    }
                    if (err == error.ConnectionClosed) return false;
                    if (err == error.Canceled) return error.Canceled;
                    const status = statusForReadError(err) orelse return false;
                    connection.writeResponse(.{
                        .status = status,
                        .reason = response_mod.reasonFor(status),
                        .headers = &.{.{
                            .name = "Connection",
                            .value = "close",
                        }},
                    }) catch {};
                    return false;
                };
                defer request.deinit(self.allocator);

                var handler_request: netz.http1.Request = .{
                    .method = request.method,
                    .target = request.target,
                    .version = request.version,
                    .headers = request.headers,
                    .body = if (state.streaming) "" else state.body.items,
                    .trailers = request.trailers,
                    .consumed = 0,
                    .must_close = request.must_close,
                };

                var response: Response = undefined;
                if (state.streaming) {
                    state.reader.?.finish();
                    response = state.future.?.await(self.io) catch |err| blk: {
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
                } else if (state.fallback_streaming) {
                    response = dispatchWithReplay(
                        self,
                        &handler_request,
                        state.client_info,
                        arena,
                        state.body.items,
                        self.options.limits,
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
                } else {
                    response = self.dispatch(
                        &handler_request,
                        state.client_info,
                        arena,
                        null,
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

                const keep_alive = request.keepAlive() and
                    !self.shutdown.isSet();
                if (!keep_alive) {
                    response.setHeader("Connection", "close") catch {};
                } else if (request.version == .http_1_0) {
                    response.setHeader("Connection", "keep-alive") catch {};
                }
                if (self.shutdown.isSet()) connection.gracefulShutdown();

                if (response.upgrade) |upgrade_body| {
                    if (try self.handleUpgrade(
                        connection,
                        &handler_request,
                        &response,
                        upgrade_body,
                        arena,
                    )) {
                        return true;
                    }
                }

                if (response.stream) |body| {
                    const body_forbidden = handler_request.method == .HEAD or
                        response.status == 204 or
                        response.status == 304 or
                        (response.status >= 100 and response.status < 200);
                    if (body_forbidden) {
                        body.cancel();
                        response.stream = null;
                        if (handler_request.method == .HEAD) {
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
                            handler_request.method,
                            handler_request.version,
                        ));
                    } else {
                        try self.writeStreaming(
                            connection,
                            &handler_request,
                            &response,
                            body,
                        );
                    }
                } else {
                    try connection.writeResponse(response.toOptionsFor(
                        handler_request.method,
                        handler_request.version,
                    ));
                }

                if (!keep_alive) return false;
            }
            return false;
        }

        fn handleUpgrade(
            self: *@This(),
            connection: *netz.http1.runtime.Connection,
            request: *const netz.http1.Request,
            response: *Response,
            upgrade: websocket_mod.Upgrade,
            arena: std.mem.Allocator,
        ) !bool {
            _ = arena;
            if (!validWebSocketUpgrade(request, upgrade.subprotocol)) {
                response.reset();
                response.setStatus(400);
                response.text("Bad Request") catch {};
                return false;
            }

            const client_key = request.header("sec-websocket-key").?;
            const accept = netz.websocket.acceptKey(client_key);
            var headers_buffer: [2]netz.http1.Header = undefined;
            headers_buffer[0] = .{
                .name = "Sec-WebSocket-Accept",
                .value = &accept,
            };
            var header_count: usize = 1;
            if (upgrade.subprotocol) |protocol| {
                headers_buffer[1] = .{
                    .name = "Sec-WebSocket-Protocol",
                    .value = protocol,
                };
                header_count = 2;
            }

            const tunnel = connection.acceptUpgrade(
                request.*,
                "websocket",
                headers_buffer[0..header_count],
            ) catch {
                response.reset();
                response.setStatus(400);
                response.text("Bad Request") catch {};
                return false;
            };

            const ws_limits = netz.websocket.runtime.Limits{
                .max_frame_bytes = self.options.limits.max_body_bytes,
                .max_message_bytes = self.options.limits.max_body_bytes,
                .tcp_nodelay = self.options.limits.tcp_nodelay,
            };
            var ws = netz.websocket.runtime.Connection{
                .io = self.io,
                .allocator = self.allocator,
                .stream = tunnel.stream,
                .role = .server,
                .limits = .{
                    .max_frame_bytes = ws_limits.max_frame_bytes,
                    .max_message_bytes = ws_limits.max_message_bytes,
                },
                .tls_server_conn = tunnel.tls_server_conn,
            };

            // Move any bytes already buffered past the HTTP request head into
            // the WebSocket connection.
            ws.inbuf = tunnel.inbuf.*;
            tunnel.inbuf.* = .empty;

            // Transport ownership moved to the WebSocket connection. Free the
            // HTTP connection's write scratch without closing the shared
            // transport.
            connection.inbuf.deinit(self.allocator);
            connection.write_scratch.deinit(self.allocator);

            var session = websocket_mod.Session{ .connection = ws };
            defer session.close();
            upgrade.run(&session) catch |err| {
                std.log.scoped(.weft).warn(
                    "websocket session failed: {s}",
                    .{@errorName(err)},
                );
            };
            return true;
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
            body_reader: ?*ctx_mod.BodyReader,
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
                body_reader,
            );
        }
    };
}

fn dispatchWithReplay(
    server: anytype,
    request: *const netz.http1.Request,
    client_info: ctx_mod.ClientInfo,
    arena: std.mem.Allocator,
    body: []const u8,
    limits: Limits,
) !Response {
    var replay = try body_stream_mod.Reader.init(
        server.allocator,
        server.io,
        limits.max_streaming_window_bytes,
    );
    defer replay.deinit();
    try replay.push(body);
    replay.finish();
    return server.dispatch(request, client_info, arena, &replay);
}

fn StreamingRead(comptime H: type) type {
    return struct {
        const Self = @This();

        server: *Server(H),
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        client_info: ctx_mod.ClientInfo,
        body: std.ArrayListUnmanaged(u8) = .empty,
        reader: ?*body_stream_mod.Reader = null,
        headers: ?[]netz.http1.Header = null,
        target: ?[]u8 = null,
        request: ?netz.http1.Request = null,
        future: ?std.Io.Future(anyerror!Response) = null,
        streaming: bool = false,
        /// Route asked for streaming but the Io backend could not run the
        /// handler concurrently; the body is buffered and replayed through a
        /// reader after the read completes.
        fallback_streaming: bool = false,
        method: netz.http1.Method = .GET,
        version: netz.http1.Version = .http_1_1,
        must_close: bool = false,

        fn onHead(self: *Self, head: netz.streaming.http1.RequestHead) !void {
            self.method = head.method;
            self.version = head.version;
            self.must_close = head.must_close;
            self.client_info.protocol = switch (head.version) {
                .http_1_0 => .http_1_0,
                .http_1_1 => .http_1_1,
                else => .http_1_1,
            };

            const target = head.target;
            const query_index = std.mem.indexOfScalar(u8, target, '?');
            const path = if (query_index) |index| target[0..index] else target;
            const resolution = try self.server.app_router.resolve(
                head.method,
                path,
                self.allocator,
            );
            switch (resolution) {
                .matched => |matched| {
                    defer matched.deinit(self.allocator);
                    if (!matched.route.streaming) return;
                },
                else => return,
            }

            var reader: ?*body_stream_mod.Reader = null;
            var reader_initialized = false;
            var headers: ?[]netz.http1.Header = null;
            var target_copy: ?[]u8 = null;
            var committed = false;
            defer if (!committed) {
                if (reader) |value| {
                    if (reader_initialized) value.deinit();
                    self.allocator.destroy(value);
                }
                if (headers) |value| self.allocator.free(value);
                if (target_copy) |value| self.allocator.free(value);
            };

            reader = try self.allocator.create(body_stream_mod.Reader);
            reader.?.* = try body_stream_mod.Reader.init(
                self.allocator,
                self.server.io,
                self.server.options.limits.max_streaming_window_bytes,
            );
            reader_initialized = true;

            headers = try self.allocator.dupe(
                netz.http1.Header,
                head.headers,
            );
            target_copy = try self.allocator.dupe(u8, target);

            self.reader = reader.?;
            self.headers = headers.?;
            self.target = target_copy.?;
            self.request = .{
                .method = head.method,
                .target = target_copy.?,
                .version = head.version,
                .headers = headers.?,
                .body = "",
                .consumed = 0,
                .must_close = head.must_close,
            };
            self.streaming = true;
            committed = true;

            self.future = std.Io.concurrent(
                self.server.io,
                Self.run,
                .{self},
            ) catch {
                self.fallback_streaming = true;
                self.clearStreaming();
                return;
            };
        }

        fn onChunk(self: *Self, chunk: []const u8) !void {
            if (self.streaming) {
                try self.reader.?.push(chunk);
                return;
            }
            const next = std.math.add(
                usize,
                self.body.items.len,
                chunk.len,
            ) catch return error.BodyTooLarge;
            if (next > self.server.options.limits.max_body_bytes) {
                return error.BodyTooLarge;
            }
            try self.body.appendSlice(self.allocator, chunk);
        }

        fn run(self: *Self) anyerror!Response {
            const reader = self.reader orelse
                return error.InvalidStreamingState;
            defer reader.drain();
            return self.server.dispatch(
                &self.request.?,
                self.client_info,
                self.arena,
                reader,
            );
        }

        fn clearStreaming(self: *Self) void {
            self.streaming = false;
            if (self.reader) |reader| {
                reader.deinit();
                self.allocator.destroy(reader);
                self.reader = null;
            }
            if (self.headers) |headers| {
                self.allocator.free(headers);
                self.headers = null;
            }
            if (self.target) |target| {
                self.allocator.free(target);
                self.target = null;
            }
            self.request = null;
        }
    };
}

fn validWebSocketUpgrade(
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
