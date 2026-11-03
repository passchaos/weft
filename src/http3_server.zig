const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const dispatch_mod = @import("dispatch.zig");
const stream_mod = @import("stream.zig");

pub const Ctx = ctx_mod.Ctx;
pub const Handler = ctx_mod.Handler;
pub const Response = response_mod.Response;
pub const Limits = limits_mod.Limits;
pub const Router = router_mod.Router;
pub const RouteOptions = router_mod.RouteOptions;

pub const Options = struct {
    address: std.Io.net.IpAddress,
    limits: Limits = .{},
    middleware: []const Handler = &.{},
    max_connections: usize = 64,
    max_requests_per_connection: usize = 1000,
    max_concurrent_streams: usize = 128,
    accept_error_backoff: std.Io.Duration = .fromMilliseconds(10),
    accept_timeout: std.Io.Duration = .fromMilliseconds(500),
    idle_timeout: std.Io.Duration = .fromSeconds(5),
    quic_limits: netz.quic.runtime.Limits = .{},
    /// QUIC/TLS server handshake options. Production deployments set
    /// `identity`, `local_connection_id`, and secure randomness here.
    handshake: netz.quic.handshake.ServerOptions,
    session: netz.http3.runtime.HandshakeSessionOptions = .{},
    serve_connection_recovery_drain_timeout: std.Io.Duration =
        .fromSeconds(5),
};

const H3StreamState = struct {
    session: *netz.http3.runtime.HandshakeServerSession,
    stream_id: u62,
    remaining: usize,
};

fn writeWithBudget(raw: ?*anyopaque, data: []const u8) anyerror!void {
    const state: *H3StreamState = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    if (data.len > state.remaining) return error.ResponseTooLarge;
    state.remaining -= data.len;
    try state.session.sendResponseBodyPaced(
        state.stream_id,
        data,
        false,
    );
}

/// A bounded HTTP/3 server adapter over Netz's QUIC/TLS handshake runtime.
///
/// Routes, middleware, request locals, decoded inputs, timeouts, and error
/// semantics are shared with HTTP/1 and HTTP/2. QUIC frame parsing, QPACK,
/// flow control, and TLS remain owned by Netz.
pub fn Http3Server(comptime H: type) type {
    comptime {
        if (H == void) {
            @compileError("weft.Http3Server requires a non-void app context; use an empty struct");
        }
    }
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        app: H,
        options: Options,
        netz_server: netz.http3.runtime.HandshakeServer,
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
                options.max_concurrent_streams == 0 or
                options.accept_timeout.nanoseconds <= 0 or
                options.idle_timeout.nanoseconds <= 0 or
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

            var http3_limits = options.limits.toHttp3Netz();
            http3_limits.quic = options.quic_limits;
            http3_limits.max_concurrent_request_streams =
                options.max_concurrent_streams;

            var session = options.session;
            session.max_stream_buffer = http3_limits.max_stream_buffer;
            session.max_concurrent_request_streams =
                options.max_concurrent_streams;
            session.auto_date_header = options.limits.auto_date_header;

            var netz_server = try netz.http3.runtime.HandshakeServer.bind(
                allocator,
                io,
                options.address,
                http3_limits,
                .{
                    .handshake = options.handshake,
                    .session = session,
                    .serve_connection_recovery_drain_timeout = options.serve_connection_recovery_drain_timeout,
                },
            );
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

        pub fn stop(self: *@This()) void {
            self.shutdown.set(self.io);
        }

        pub fn serve(self: *@This()) !void {
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

            group.await(self.io) catch |err| {
                group.cancel(self.io);
                group_finished = true;
                return err;
            };
            group_finished = true;
        }

        /// QUIC owns one UDP endpoint, so a single accept loop admits
        /// handshakes while a semaphore bounds concurrently served sessions.
        fn acceptWorker(
            self: *@This(),
            group: *std.Io.Group,
            semaphore: *std.Io.Semaphore,
        ) std.Io.Cancelable!void {
            while (true) {
                if (self.shutdown.isSet()) return;

                try semaphore.wait(self.io);
                const session = self.netz_server.acceptWithTimeout(
                    self.options.accept_timeout,
                ) catch |err| {
                    semaphore.post(self.io);
                    if (err == error.Canceled) return error.Canceled;
                    if (err == error.Timeout) continue;
                    if (self.shutdown.isSet()) return;
                    std.log.scoped(.weft).warn(
                        "http3 accept failed: {s}",
                        .{@errorName(err)},
                    );
                    std.Io.sleep(
                        self.io,
                        self.options.accept_error_backoff,
                        .awake,
                    ) catch return error.Canceled;
                    continue;
                };

                group.async(self.io, sessionWorker, .{
                    self,
                    session,
                    semaphore,
                });
            }
        }

        fn sessionWorker(
            self: *@This(),
            session: netz.http3.runtime.HandshakeServerSession,
            semaphore: *std.Io.Semaphore,
        ) std.Io.Cancelable!void {
            var owned_session = session;
            defer {
                owned_session.deinit();
                semaphore.post(self.io);
            }

            self.serveSession(&owned_session) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                std.log.scoped(.weft).warn(
                    "http3 connection error: {s}",
                    .{@errorName(err)},
                );
            };
        }

        fn serveSession(
            self: *@This(),
            session: *netz.http3.runtime.HandshakeServerSession,
        ) !void {
            var served: usize = 0;
            while (served < self.options.max_requests_per_connection) : (served += 1) {
                if (self.shutdown.isSet()) {
                    session.initiateShutdown() catch {};
                    return;
                }

                var request = session.receiveRequestWithTimeout(
                    self.options.idle_timeout,
                ) catch |err| {
                    if (err == error.Timeout) {
                        if (self.shutdown.isSet()) {
                            session.initiateShutdown() catch {};
                            return;
                        }
                        continue;
                    }
                    if (err == error.Canceled) return error.Canceled;
                    return;
                };
                defer request.deinit(self.allocator);

                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();

                const client_info = ctx_mod.ClientInfo{
                    .address = request.from,
                    .protocol = .http_3,
                    .tls = true,
                };
                var response = self.dispatch(
                    &request.request,
                    client_info,
                    arena.allocator(),
                ) catch |err| blk: {
                    if (err == error.Canceled) return error.Canceled;
                    std.log.scoped(.weft).warn(
                        "http3 dispatch failed: {s}",
                        .{@errorName(err)},
                    );
                    break :blk internalErrorResponse(
                        arena.allocator(),
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

                try self.respond(
                    session,
                    request.stream_id,
                    &request.request,
                    &response,
                    arena.allocator(),
                );
            }

            session.initiateShutdown() catch {};
        }

        fn dispatch(
            self: *@This(),
            decoded: *const netz.http3.DecodedRequest,
            client_info: ctx_mod.ClientInfo,
            arena: std.mem.Allocator,
        ) !Response {
            const method = netz.http1.Method.parse(decoded.method) catch
                return error.InvalidMethod;
            const target = if (decoded.path.len == 0) "/" else decoded.path;

            var header_count: usize = 0;
            for (decoded.headers) |field| {
                if (!isPseudoHeader(field.name)) header_count += 1;
            }
            const has_host = findHeader(decoded.headers, "host") != null;
            const add_host = decoded.authority != null and !has_host;
            if (add_host) header_count += 1;

            const headers = try arena.alloc(netz.http1.Header, header_count);
            var index: usize = 0;
            for (decoded.headers) |field| {
                if (isPseudoHeader(field.name)) continue;
                headers[index] = .{ .name = field.name, .value = field.value };
                index += 1;
            }
            if (add_host) {
                headers[index] = .{
                    .name = "Host",
                    .value = decoded.authority.?,
                };
            }

            var request = netz.http1.Request{
                .method = method,
                .target = target,
                .version = .http_1_1,
                .headers = headers,
                .body = decoded.body,
                .consumed = 0,
            };

            return dispatch_mod.dispatch(
                H,
                &self.app,
                &self.app_router,
                self.io,
                self.options.limits,
                self.options.middleware,
                &request,
                client_info,
                arena,
            );
        }

        fn respond(
            self: *@This(),
            session: *netz.http3.runtime.HandshakeServerSession,
            stream_id: u62,
            decoded: *const netz.http3.DecodedRequest,
            response: *Response,
            arena: std.mem.Allocator,
        ) !void {
            if (response.stream) |body| {
                const body_forbidden = std.mem.eql(u8, decoded.method, "HEAD") or
                    response.status == 204 or
                    response.status == 304 or
                    (response.status >= 100 and response.status < 200);
                if (body_forbidden) {
                    body.cancel();
                    response.stream = null;
                    if (std.mem.eql(u8, decoded.method, "HEAD")) {
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
                    try self.writeBuffered(
                        session,
                        stream_id,
                        decoded,
                        response,
                        arena,
                    );
                    return;
                }

                if (body.length) |length| {
                    if (length > self.options.limits.max_response_bytes) {
                        body.cancel();
                        return error.ResponseTooLarge;
                    }
                    response.setHeader(
                        "Content-Length",
                        try std.fmt.allocPrint(arena, "{d}", .{length}),
                    ) catch {};
                }
                try self.writeStreaming(
                    session,
                    stream_id,
                    decoded,
                    response,
                    body,
                    arena,
                );
                return;
            }

            try self.writeBuffered(
                session,
                stream_id,
                decoded,
                response,
                arena,
            );
        }

        fn writeBuffered(
            self: *@This(),
            session: *netz.http3.runtime.HandshakeServerSession,
            stream_id: u62,
            decoded: *const netz.http3.DecodedRequest,
            response: *Response,
            arena: std.mem.Allocator,
        ) !void {
            _ = self;
            const h3_response = try toHttp3Response(
                response,
                decoded.method,
                arena,
            );
            try session.sendResponsePaced(stream_id, h3_response);
        }

        fn writeStreaming(
            self: *@This(),
            session: *netz.http3.runtime.HandshakeServerSession,
            stream_id: u62,
            decoded: *const netz.http3.DecodedRequest,
            response: *Response,
            body: stream_mod.Body,
            arena: std.mem.Allocator,
        ) !void {
            const h3_response = try toHttp3Response(
                response,
                decoded.method,
                arena,
            );
            session.startResponse(
                stream_id,
                h3_response,
                body.length,
            ) catch |err| {
                body.cancel();
                return err;
            };

            var state = H3StreamState{
                .session = session,
                .stream_id = stream_id,
                .remaining = body.length orelse
                    self.options.limits.max_response_bytes,
            };
            var stream_writer = stream_mod.Writer{
                .context = &state,
                .write_fn = writeWithBudget,
            };
            try body.run(&stream_writer);
            try session.sendResponseBodyPaced(stream_id, "", true);
            response.stream = null;
        }
    };
}

fn toHttp3Response(
    response: *const Response,
    method: []const u8,
    arena: std.mem.Allocator,
) !netz.http3.Response {
    return .{
        .status = response.status,
        .headers = try headerFields(response, arena),
        .body = response.body,
        .request_method = method,
    };
}

fn headerFields(
    response: *const Response,
    arena: std.mem.Allocator,
) ![]const netz.http3.Qpack.HeaderField {
    var fields = std.ArrayListUnmanaged(netz.http3.Qpack.HeaderField).empty;
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
    headers: []const netz.http3.Qpack.HeaderField,
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
