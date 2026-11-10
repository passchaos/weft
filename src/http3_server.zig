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

const WsContext = struct {
    stream: *netz.http3.runtime.HandshakeServerSession.ConcurrentStream,
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

const Ctx = ctx_mod.Ctx;
const Handler = handler_mod.Handler;
const Response = response_mod.Response;
const Limits = limits_mod.Limits;
const Router = router_mod.Router;
const RouteOptions = router_mod.RouteOptions;

pub const Options = struct {
    address: std.Io.net.IpAddress,
    limits: Limits = .{},
    middleware: []const Handler = &.{},
    not_found: ?Handler = null,
    bad_request: ?Handler = null,
    method_not_allowed: ?Handler = null,
    max_connections: usize = 64,
    max_requests_per_connection: usize = 1000,
    max_concurrent_streams: usize = 128,
    /// Maximum handler tasks running concurrently per connection. Also caps
    /// the advertised request-stream concurrency so buffered requests stay
    /// bounded.
    max_concurrent_handlers: usize = 8,
    /// Poll interval used while handlers are active and no new request is
    /// immediately available. The concurrent engine also uses this as its
    /// command/receive poll budget, so a shorter interval directly reduces
    /// per-request latency.
    handler_poll_interval: std.Io.Duration = .fromMilliseconds(1),
    /// Optional cap on handler worker threads per connection. Null keeps one
    /// worker per possible concurrent handler.
    max_handler_threads: ?usize = null,
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
    /// Optional budget for the accept loop and sessions to drain after `stop`.
    drain_timeout: ?std.Io.Duration = .fromSeconds(5),
};

/// A bounded HTTP/3 server adapter over Netz's QUIC/TLS handshake runtime.
///
/// Routes, middleware, request locals, decoded inputs, timeouts, and error
/// semantics are shared with HTTP/1 and HTTP/2. QUIC frame parsing, QPACK,
/// flow control, and TLS remain owned by Netz. The connection owner serializes
/// all session mutations while handlers run concurrently per stream.
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

        const ConcurrentStream = netz.http3.runtime.HandshakeServerSession.ConcurrentStream;

        pub fn init(
            io: std.Io,
            allocator: std.mem.Allocator,
            options: Options,
            app: H,
        ) !@This() {
            if (options.max_connections == 0 or
                options.max_requests_per_connection == 0 or
                options.max_concurrent_streams == 0 or
                options.max_concurrent_handlers == 0 or
                (options.max_handler_threads != null and
                    options.max_handler_threads.? == 0) or
                options.handler_poll_interval.nanoseconds <= 0 or
                options.accept_error_backoff.nanoseconds <= 0 or
                options.accept_timeout.nanoseconds <= 0 or
                options.idle_timeout.nanoseconds <= 0 or
                options.serve_connection_recovery_drain_timeout.nanoseconds <= 0 or
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

            const effective_concurrency = @min(
                options.max_concurrent_streams,
                options.max_concurrent_handlers,
            );
            var http3_limits = options.limits.toHttp3Netz();
            http3_limits.quic = options.quic_limits;
            http3_limits.max_concurrent_request_streams =
                effective_concurrency;

            var session = options.session;
            session.max_stream_buffer = http3_limits.max_stream_buffer;
            session.max_concurrent_request_streams =
                effective_concurrency;
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
                    logging_mod.logWarn(
                        "weft",
                        "http3 accept failed: {s}",
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
                logging_mod.logWarn(
                    "weft",
                    "http3 connection error: {s}",
                    .{@errorName(err)},
                    .{ .err = @errorName(err) },
                );
            };
        }

        fn serveSession(
            self: *@This(),
            session: *netz.http3.runtime.HandshakeServerSession,
        ) !void {
            const capacity = @min(
                self.options.max_concurrent_streams,
                self.options.max_concurrent_handlers,
            );
            var context = H3ConcurrentContext(H){
                .server = self,
                .peer_certificates = session.peerCertificates() orelse &.{},
                .max_requests = self.options.max_requests_per_connection,
            };
            var watcher = self.io.async(
                H3ShutdownWatch.run,
                .{ self.io, &self.shutdown, &context.session_shutdown },
            );
            defer {
                context.session_shutdown.set(self.io);
                _ = watcher.cancel(self.io);
            }

            _ = session.serveConcurrentStreams(
                H3ConcurrentContext(H),
                &context,
                handleConcurrentStream,
                .{
                    .max_streams = capacity,
                    .idle_timeout = self.options.idle_timeout,
                    .shutdown = &context.session_shutdown,
                    .poll_interval = self.options.handler_poll_interval,
                    .max_worker_threads = self.options.max_handler_threads,
                    .max_buffered_body_bytes = self.options.limits.max_streaming_window_bytes,
                    .inline_bodyless = self.app_router.hasInlineBodylessRoutes(),
                },
            ) catch |err| {
                if (err == error.Canceled) return err;
                // Idle connections close through `idle_timeout`; that is a
                // normal lifecycle event, not a connection failure.
                if (err == error.Timeout) return;
                logging_mod.logWarn(
                    "weft",
                    "http3 serve failed: {s}",
                    .{@errorName(err)},
                    .{ .err = @errorName(err) },
                );
                return err;
            };
        }

        fn handleConcurrentStream(
            context: *H3ConcurrentContext(H),
            stream: *ConcurrentStream,
        ) anyerror!void {
            try context.server.serveConcurrentStream(
                stream,
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
                stream.reset(
                    netz.http3.ApplicationErrorCode.general_protocol_error,
                ) catch {};
                return;
            };
            const target = if (head.path.len == 0) "/" else head.path;
            const websocket_upgrade = method == .CONNECT and blk: {
                const protocol = findHeader(head.headers, ":protocol") orelse
                    break :blk false;
                break :blk std.mem.eql(u8, protocol, "websocket");
            };

            // Route matching uses the path, never the query string carried by
            // the `:path` pseudo-header. Match once and reuse the result for
            // both the inline eligibility check and dispatch; `prepareRoute`
            // resets the counts before any read.
            var prepared: router_mod.Prepared = undefined;
            dispatch_mod.prepareRoute(
                H,
                &self.app_router,
                if (websocket_upgrade) .GET else method,
                target,
                &prepared,
            );

            // Inline handlers run on the QUIC owner. Decline before any side
            // effect when the route did not opt in, needs a streaming body,
            // or hits a rejection path.
            if (stream.isInline()) {
                const route = prepared.route orelse
                    return error.InlineDeclined;
                if (method == .CONNECT or
                    websocket_upgrade or
                    !route.inline_bodyless or
                    (route.streaming and !stream.inlineBodyComplete()) or
                    target.len > self.options.limits.max_request_target_bytes or
                    head.headers.len > self.options.limits.max_request_headers)
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
            // Netz's HTTP/3 limits bound the reassembled stream, not the field
            // count or QPACK field-section size, so enforce the same budgets
            // the HTTP/1 and HTTP/2 adapters apply.
            var field_count: usize = 0;
            var field_bytes: usize = 0;
            for (head.headers) |field| {
                if (isPseudoHeader(field.name)) continue;
                field_count += 1;
                field_bytes = field_bytes +| field.name.len +|
                    field.value.len +| 32;
            }
            if (head.authority) |authority| {
                if (findHeader(head.headers, "host") == null) {
                    field_count += 1;
                    field_bytes = field_bytes +| "host".len +|
                        authority.len +| 32;
                }
            }
            if (field_count > self.options.limits.max_request_headers or
                field_bytes > self.options.limits.max_head_bytes)
            {
                return self.rejectConcurrent(
                    stream,
                    head.method,
                    431,
                    "Request Header Fields Too Large",
                    arena,
                );
            }
            // Common requests fit a stack header view, so the request arena
            // stays untouched until the handler or response actually needs it.
            var header_stack: [32]netz.http1.Header = undefined;
            const headers = convertH3HeadHeadersInto(
                header_stack[0..],
                head.headers,
                head.authority,
            ) orelse (convertH3HeadHeaders(
                arena,
                head.headers,
                head.authority,
            ) catch {
                stream.reset(
                    netz.http3.ApplicationErrorCode.internal_error,
                ) catch {};
                return;
            });

            const streaming = if (websocket_upgrade)
                false
            else if (prepared.route) |route|
                route.streaming
            else
                false;
            // Keep the 16 KiB reader buffer uninitialized. An optional holding
            // it would zero the whole payload on every request, including
            // non-streaming routes.
            var h3_reader: body_mod.H3StreamReader = undefined;
            var body_reader: ?body_mod.BodyReader = null;
            var body: []const u8 = "";
            var trailers: []netz.http1.Header = &.{};

            if (streaming) {
                h3_reader = body_mod.H3StreamReader.init(
                    stream,
                    self.options.limits.max_streaming_window_bytes,
                );
                body_reader = .{ .h3_stream = &h3_reader };
            } else {
                body = readWholeBody(
                    arena,
                    self.allocator,
                    stream,
                    head.content_length,
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
                    trailers = convertH3Trailers(arena, fields) catch &.{};
                }
            }

            var request = netz.http1.Request{
                .method = if (websocket_upgrade) .GET else method,
                .target = target,
                .version = .http_1_1,
                .headers = headers,
                .body = body,
                .trailers = trailers,
                .consumed = 0,
            };
            const client_info = handler_mod.ClientInfo{
                .address = handler_mod.resolveClientAddress(
                    head.headers,
                    stream.from(),
                    self.options.limits.trust_forwarded_for,
                ),
                .peer_certificates = peer_certificates,
                .protocol = .http_3,
                .tls = true,
            };
            var response = self.dispatchRequest(
                &request,
                client_info,
                arena,
                body_reader,
                &prepared,
                .{},
            ) catch |err| blk: {
                if (err == error.Canceled) return err;
                logging_mod.logWarn(
                    "weft",
                    "http3 dispatch failed: {s}",
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
                        "http3 response failed: {s}",
                        .{@errorName(err)},
                        .{ .err = @errorName(err) },
                    );
                } else {
                    logging_mod.logWarn(
                        "weft",
                        "http3 response failed: {s}",
                        .{@errorName(err)},
                        .{ .err = @errorName(err) },
                    );
                }
                stream.reset(
                    netz.http3.ApplicationErrorCode.internal_error,
                ) catch {};
            };
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

            var fields = std.ArrayListUnmanaged(netz.http3.Qpack.HeaderField).empty;
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
            }, null);

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

            const body_forbidden = responseBodyForbidden(method, response.status);
            var head_length: ?usize = null;

            if (response.stream) |body| {
                if (body_forbidden) {
                    if (std.mem.eql(u8, method, "HEAD")) {
                        if (body.length) |length| {
                            head_length = length;
                            response.setHeader(
                                "Content-Length",
                                std.fmt.allocPrint(
                                    arena,
                                    "{d}",
                                    .{length},
                                ) catch return error.OutOfMemory,
                            ) catch return error.OutOfMemory;
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
                        std.fmt.allocPrint(
                            arena,
                            "{d}",
                            .{length},
                        ) catch return error.OutOfMemory,
                    ) catch return error.OutOfMemory;
                }
            }

            // Body and trailers are written after the head, so only the
            // header fields are converted here.
            const h3_response = netz.http3.Response{
                .status = response.status,
                .headers = try headerFields(response, arena),
                .body = &.{},
                .trailers = &.{},
                .request_method = method,
            };

            if (body_forbidden) {
                const length: ?usize = if (std.mem.eql(u8, method, "HEAD"))
                    (head_length orelse
                        if (response.body.len != 0) response.body.len else null)
                else
                    null;
                try stream.startResponse(h3_response, length);
                return;
            }

            if (response.stream) |body| {
                if (body.length == 0 and response.trailers.items.len == 0) {
                    body.cancel();
                    response.stream = null;
                    try stream.startResponse(h3_response, 0);
                    return;
                }
                const length = if (body.length) |value|
                    if (value == 0 and response.trailers.items.len != 0)
                        null
                    else
                        value
                else
                    null;
                try stream.startResponse(h3_response, length);

                var state = H3ConcurrentWriterState{
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
                    stream.reset(
                        netz.http3.ApplicationErrorCode.internal_error,
                    ) catch {};
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

            if (response.body.len == 0 and response.trailers.items.len == 0) {
                try stream.startResponse(h3_response, 0);
                return;
            }

            // Head and the buffered body share one owner turn; the engine can
            // also emit a complete sequential response in one QUIC packet.
            if (response.trailers.items.len != 0) {
                if (response.body.len == 0) {
                    try stream.startResponse(h3_response, null);
                } else {
                    try stream.startResponseWithBody(
                        h3_response,
                        response.body.len,
                        response.body,
                        false,
                    );
                }
                try stream.finishWithTrailers(
                    try trailerFields(response, arena),
                );
            } else {
                try stream.startResponseWithBody(
                    h3_response,
                    response.body.len,
                    response.body,
                    true,
                );
            }
        }
    };
}

fn H3ConcurrentContext(comptime H: type) type {
    return struct {
        server: *Http3Server(H),
        peer_certificates: []const []const u8 = &.{},
        session_shutdown: std.Io.Event = .unset,
        completed: std.atomic.Value(usize) = .init(0),
        max_requests: usize = 0,
    };
}

const H3ShutdownWatch = struct {
    fn run(
        io: std.Io,
        source: *std.Io.Event,
        target: *std.Io.Event,
    ) void {
        source.wait(io) catch return;
        target.set(io);
    }
};

const H3ConcurrentWriterState = struct {
    stream: *netz.http3.runtime.HandshakeServerSession.ConcurrentStream,
    remaining: usize,
};

fn writeConcurrentWithBudget(
    raw: ?*anyopaque,
    data: []const u8,
) anyerror!void {
    const state: *H3ConcurrentWriterState = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    try adapter_write.consume(&state.remaining, data);
    try state.stream.writeData(data, false);
}

const readWholeBody = adapter_body.readWholeBody;

fn responseBodyForbidden(method: []const u8, status: u16) bool {
    return std.mem.eql(u8, method, "HEAD") or
        status == 204 or
        status == 304 or
        (status >= 100 and status < 200);
}

const HeaderView = adapter_header.HeaderView(netz.http3.Qpack.HeaderField);
const convertH3Trailers = HeaderView.convertTrailers;
const convertH3HeadHeadersInto = HeaderView.convertHeadersInto;
const convertH3HeadHeaders = HeaderView.convertHeaders;
const trailerFields = HeaderView.trailerFields;
const headerFields = HeaderView.headerFields;
const lowerHeaderName = HeaderView.lowerHeaderName;
const forbiddenResponseHeader = HeaderView.forbiddenResponseHeader;
const isPseudoHeader = HeaderView.isPseudoHeader;
const findHeader = HeaderView.findHeader;
const internalErrorResponse = adapter_response.internalErrorResponse;

test "h3 request trailers convert to the http1 header view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fields = [_]netz.http3.Qpack.HeaderField{
        .{ .name = "x-checksum", .value = "abc" },
        .{ .name = "x-trace", .value = "one" },
    };
    const headers = try convertH3Trailers(arena.allocator(), &fields);
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("x-checksum", headers[0].name);
    try std.testing.expectEqualStrings("abc", headers[0].value);
    try std.testing.expectEqualStrings("one", headers[1].value);
}
