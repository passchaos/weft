const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const errors_mod = @import("errors.zig");
const limits_mod = @import("limits.zig");
const dispatch_mod = @import("dispatch.zig");
const stream_mod = @import("stream.zig");
const drain_mod = @import("drain.zig");

pub const Ctx = ctx_mod.Ctx;
pub const Handler = ctx_mod.Handler;
pub const Response = response_mod.Response;
pub const Limits = limits_mod.Limits;
pub const Router = router_mod.Router;
pub const RouteOptions = router_mod.RouteOptions;

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
    /// TCP accept plus TLS/HTTP/2 bootstrap budget for TLS workers.
    tls_accept_timeout: std.Io.Duration = .fromMilliseconds(500),
    /// Optional budget for workers to drain after `stop`.
    drain_timeout: ?std.Io.Duration = .fromSeconds(5),
};

const Listener = union(enum) {
    plain: netz.http2.runtime.Server,
    tls: netz.http2.runtime.TlsServer,
    unix: netz.http2.runtime.UnixServer,

    fn deinit(self: *Listener) void {
        switch (self.*) {
            .plain => |*server| server.deinit(),
            .tls => |*server| server.deinit(),
            .unix => |*server| server.deinit(),
        }
    }

    fn address(self: *const Listener) ?std.Io.net.IpAddress {
        return switch (self.*) {
            .plain => |server| server.address(),
            .tls => |server| server.address(),
            .unix => null,
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
    if (data.len > state.remaining) return error.ResponseTooLarge;
    state.remaining -= data.len;
    try state.writer.write(data);
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
                options.limits.max_request_headers == 0 or
                options.limits.max_body_bytes == 0 or
                options.limits.max_request_arena_bytes == 0 or
                options.limits.max_streaming_window_bytes == 0 or
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
            ) } else if (options.tls) |tls_options| blk: {
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
                var connection = self.netz_server.acceptWithTimeout(
                    accept_timeout,
                ) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    if (err == error.Timeout) continue;
                    if (self.shutdown.isSet()) return;
                    std.log.scoped(.weft).warn(
                        "http2 accept failed: {s}",
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
                        "http2 connection error: {s}",
                        .{@errorName(err)},
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
                },
            ) catch |err| {
                if (err == error.Canceled) return err;
                // Idle connections close through `idle_timeout`; that is a
                // normal lifecycle event, not a connection failure.
                if (err == error.Timeout) return;
                std.log.scoped(.weft).warn(
                    "http2 serve failed: {s}",
                    .{@errorName(err)},
                );
                return err;
            };
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
            const arena_buffer = try self.allocator.alloc(
                u8,
                self.options.limits.max_request_arena_bytes,
            );
            defer self.allocator.free(arena_buffer);
            var fixed = std.heap.FixedBufferAllocator.init(arena_buffer);
            const arena = fixed.allocator();

            const head = stream.head();
            const method = netz.http1.Method.parse(head.method) catch {
                stream.reset(.protocol_error) catch {};
                return;
            };
            // Weft has no CONNECT tunnel or extended-CONNECT API; reject the
            // stream instead of routing the authority target as a request.
            if (method == .CONNECT) {
                return self.rejectConcurrent(
                    stream,
                    head.method,
                    501,
                    "Not Implemented",
                    arena,
                );
            }
            const target = if (head.path.len == 0) "/" else head.path;
            if (target.len > self.options.limits.max_request_target_bytes) {
                return self.rejectConcurrent(
                    stream,
                    head.method,
                    414,
                    "URI Too Long",
                    arena,
                );
            }
            const headers = convertH2Headers(
                arena,
                head.headers,
                head.authority,
            ) catch {
                stream.reset(.internal_error) catch {};
                return;
            };

            // The concurrent engine only publishes body completion while it is
            // draining a stream, so a request with no DATA frames cannot be
            // read to completion from the handler. Use the declared length to
            // avoid waiting for a body that cannot arrive, and keep the
            // streaming reader for routes that opted in or for unknown-length
            // bodies.
            const route_streaming = self.app_router.isStreaming(method, target);
            const declared_length = head.content_length;
            const has_declared_body = declared_length != null and
                declared_length.? != 0;
            const streaming = route_streaming or declared_length == null;
            var body: []const u8 = "";
            var trailers: []netz.http1.Header = &.{};
            var h2_reader: ctx_mod.H2StreamReader = undefined;
            var reader: ?ctx_mod.BodyReader = null;
            if (streaming) {
                h2_reader = ctx_mod.H2StreamReader.init(
                    stream,
                    self.options.limits.max_streaming_window_bytes,
                );
                reader = .{ .h2_stream = &h2_reader };
            } else if (has_declared_body) {
                body = readWholeBody(
                    arena,
                    stream,
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
                .method = method,
                .target = target,
                .version = .http_1_1,
                .headers = headers,
                .body = body,
                .trailers = trailers,
                .consumed = 0,
                .must_close = false,
            };
            const client_info = ctx_mod.ClientInfo{
                .address = ctx_mod.resolveClientAddress(
                    head.headers,
                    peer_address,
                    self.options.limits.trust_forwarded_for,
                ),
                .peer_certificates = peer_certificates,
                .protocol = .http_2,
                .tls = self.options.tls != null,
            };
            var response = self.dispatchRequest(
                &request,
                client_info,
                arena,
                reader,
            ) catch |err| blk: {
                if (err == error.Canceled) return err;
                std.log.scoped(.weft).warn(
                    "http2 dispatch failed: {s}",
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

            self.respondConcurrent(
                stream,
                head.method,
                &response,
                arena,
            ) catch |err| {
                if (err == error.Canceled) return err;
                if (errors_mod.isPeerDisconnect(err)) {
                    std.log.scoped(.weft).debug(
                        "http2 response failed: {s}",
                        .{@errorName(err)},
                    );
                } else {
                    std.log.scoped(.weft).warn(
                        "http2 response failed: {s}",
                        .{@errorName(err)},
                    );
                }
                stream.reset(.internal_error) catch {};
            };
        }

        /// Answer a request that exceeded an adapter budget without running
        /// the router.
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
            try stream.startResponse(options);

            // Netz ends the stream in the response head for HEAD/204/304, so
            // any DATA or finish command here would target a finished stream.
            if (body_forbidden) return;

            if (response.stream) |body| {
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

            if (response.trailers.items.len != 0) {
                try stream.writeData(response.body, false);
                try stream.finishWithTrailers(
                    try trailerFields(response, arena),
                );
            } else {
                try stream.writeData(response.body, true);
            }
        }

        fn dispatchRequest(
            self: *@This(),
            request: *const netz.http1.Request,
            client_info: ctx_mod.ClientInfo,
            arena: std.mem.Allocator,
            body_reader: ?ctx_mod.BodyReader,
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
    if (data.len > state.remaining) return error.ResponseTooLarge;
    state.remaining -= data.len;
    try state.stream.writeData(data, false);
}

fn readWholeBody(
    arena: std.mem.Allocator,
    stream: *netz.http2.runtime.Connection.ConcurrentStream,
    max_body_bytes: usize,
    max_arena_bytes: usize,
) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8).empty;
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const count = (try stream.nextBody(&buffer, null)) orelse break;
        if (count == 0) continue;
        const total = std.math.add(usize, output.items.len, count) catch
            return error.PayloadTooLarge;
        if (total > max_body_bytes or total > max_arena_bytes) {
            return error.PayloadTooLarge;
        }
        output.appendSlice(arena, buffer[0..count]) catch
            return error.PayloadTooLarge;
    }
    return output.items;
}

fn convertH2Trailers(
    allocator: std.mem.Allocator,
    fields: []const netz.http2.Hpack.HeaderField,
) ![]netz.http1.Header {
    const headers = try allocator.alloc(netz.http1.Header, fields.len);
    for (fields, headers) |field, *header| {
        header.* = .{ .name = field.name, .value = field.value };
    }
    return headers;
}

fn convertH2Headers(
    allocator: std.mem.Allocator,
    fields: []const netz.http2.Hpack.HeaderField,
    authority: ?[]const u8,
) ![]netz.http1.Header {
    var count: usize = 0;
    for (fields) |field| {
        if (!isPseudoHeader(field.name)) count += 1;
    }
    const has_host = findHeader(fields, "host") != null;
    const add_host = authority != null and !has_host;
    if (add_host) count += 1;

    const headers = try allocator.alloc(netz.http1.Header, count);
    var index: usize = 0;
    for (fields) |field| {
        if (isPseudoHeader(field.name)) continue;
        headers[index] = .{ .name = field.name, .value = field.value };
        index += 1;
    }
    if (add_host) {
        headers[index] = .{
            .name = "Host",
            .value = authority.?,
        };
    }
    return headers;
}

fn trailerFields(
    response: *const Response,
    arena: std.mem.Allocator,
) ![]const netz.http2.Hpack.HeaderField {
    var fields = std.ArrayListUnmanaged(netz.http2.Hpack.HeaderField).empty;
    for (response.trailers.items) |header| {
        const name = try arena.alloc(u8, header.name.len);
        for (header.name, name) |source, *target| {
            target.* = std.ascii.toLower(source);
        }
        try fields.append(arena, .{
            .name = name,
            .value = header.value,
        });
    }
    return fields.toOwnedSlice(arena);
}

fn headerFields(
    response: *const Response,
    arena: std.mem.Allocator,
) ![]const netz.http2.Hpack.HeaderField {
    var fields = std.ArrayListUnmanaged(netz.http2.Hpack.HeaderField).empty;
    for (response.headers.items) |header| {
        if (forbiddenResponseHeader(header.name)) continue;
        const name = try arena.alloc(u8, header.name.len);
        for (header.name, name) |source, *target| {
            target.* = std.ascii.toLower(source);
        }
        try fields.append(arena, .{
            .name = name,
            .value = header.value,
        });
    }
    return fields.toOwnedSlice(arena);
}

fn forbiddenResponseHeader(name: []const u8) bool {
    if (name.len == 0 or name[0] == ':') return true;
    inline for (.{
        "connection",
        "keep-alive",
        "proxy-connection",
        "transfer-encoding",
        "upgrade",
        "host",
        "te",
    }) |forbidden| {
        if (std.ascii.eqlIgnoreCase(name, forbidden)) return true;
    }
    return false;
}

fn isPseudoHeader(name: []const u8) bool {
    return name.len > 0 and name[0] == ':';
}

fn findHeader(
    headers: []const netz.http2.Hpack.HeaderField,
    name: []const u8,
) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
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
