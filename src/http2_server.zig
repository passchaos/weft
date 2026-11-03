const std = @import("std");
const netz = @import("netz");
const body_stream_mod = @import("body_stream.zig");
const ctx_mod = @import("ctx.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
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
    address: std.Io.net.IpAddress,
    limits: Limits = .{},
    /// Application middleware that runs for matched routes, `404`, `405`,
    /// `400`, and automatic `OPTIONS`. The slice must outlive the server.
    middleware: []const Handler = &.{},
    not_found: ?Handler = null,
    bad_request: ?Handler = null,
    method_not_allowed: ?Handler = null,
    max_connections: usize = 256,
    max_requests_per_connection: usize = 1000,
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
    ) !netz.http2.runtime.Connection {
        return switch (self.*) {
            .plain => |*server| server.acceptWithTimeout(timeout),
            .tls => |*server| server.acceptWithTimeout(timeout),
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
/// owns one connection and serves requests sequentially through the same
/// application dispatch path.
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
                options.accept_timeout.nanoseconds <= 0 or
                options.idle_timeout.nanoseconds <= 0 or
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
                tls.limits = options.limits.toHttp2Netz();
                tls.tcp_nodelay = options.limits.tcp_nodelay;
                break :blk .{ .tls = try netz.http2.runtime.TlsServer.listen(
                    allocator,
                    io,
                    options.address,
                    tls,
                ) };
            } else .{ .plain = try netz.http2.runtime.Server.listen(
                allocator,
                io,
                options.address,
                options.limits.toHttp2Netz(),
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

        fn serveConnection(
            self: *@This(),
            connection: *netz.http2.runtime.Connection,
        ) !void {
            var served: usize = 0;
            var last_stream_id: u31 = 0;
            const arena_buffer = try self.allocator.alloc(
                u8,
                self.options.limits.max_request_arena_bytes,
            );
            defer self.allocator.free(arena_buffer);

            while (served < self.options.max_requests_per_connection) : (served += 1) {
                if (self.shutdown.isSet()) {
                    connection.sendGoAway(
                        last_stream_id,
                        .no_error,
                        "shutdown",
                    ) catch {};
                    return;
                }

                var fixed_arena = std.heap.FixedBufferAllocator.init(
                    arena_buffer,
                );
                const arena = fixed_arena.allocator();

                var state = H2StreamingRead(H){
                    .server = self,
                    .connection = connection,
                    .allocator = self.allocator,
                    .arena = arena,
                    .client_info = .{
                        .address = connection.stream.socket.address,
                        .protocol = .http_2,
                        .tls = self.options.tls != null,
                    },
                };
                defer state.body.deinit(self.allocator);
                defer state.clearStreaming();

                var request = connection.readRequestStreamingWithHeadAndTimeout(
                    self.options.idle_timeout,
                    &state,
                    H2StreamingRead(H).onHead,
                    H2StreamingRead(H).onChunk,
                ) catch |err| {
                    if (state.streaming) {
                        state.reader.?.finish();
                        if (state.future) |*future| {
                            _ = future.await(self.io) catch {};
                        }
                    }
                    if (err == error.Timeout) {
                        if (self.shutdown.isSet()) {
                            connection.sendGoAway(
                                last_stream_id,
                                .no_error,
                                "shutdown",
                            ) catch {};
                            return;
                        }
                        continue;
                    }
                    if (err == error.Canceled) return error.Canceled;
                    return;
                };
                defer request.deinit(self.allocator);
                last_stream_id = request.stream_id;

                const method = netz.http1.Method.parse(request.method) catch
                    return;
                const target = if (request.path.len == 0) "/" else request.path;

                var response: Response = undefined;
                if (state.streaming) {
                    state.reader.?.finish();
                    response = state.future.?.await(self.io) catch |err| blk: {
                        if (err == error.Canceled) return error.Canceled;
                        std.log.scoped(.weft).warn(
                            "http2 dispatch failed: {s}",
                            .{@errorName(err)},
                        );
                        break :blk internalErrorResponse(
                            arena,
                            self.options.limits,
                        );
                    };
                } else {
                    const headers = try convertH2Headers(
                        arena,
                        request.headers,
                        request.authority,
                    );
                    var handler_request = netz.http1.Request{
                        .method = method,
                        .target = target,
                        .version = .http_1_1,
                        .headers = headers,
                        .body = state.body.items,
                        .consumed = 0,
                    };

                    if (state.fallback_streaming) {
                        response = dispatchReplayH2(
                            self,
                            &handler_request,
                            state.client_info,
                            arena,
                            state.body.items,
                            self.options.limits,
                        ) catch |err| blk: {
                            if (err == error.Canceled) return error.Canceled;
                            std.log.scoped(.weft).warn(
                                "http2 dispatch failed: {s}",
                                .{@errorName(err)},
                            );
                            break :blk internalErrorResponse(
                                arena,
                                self.options.limits,
                            );
                        };
                    } else {
                        response = self.dispatchRequest(
                            &handler_request,
                            state.client_info,
                            arena,
                            null,
                        ) catch |err| blk: {
                            if (err == error.Canceled) return error.Canceled;
                            std.log.scoped(.weft).warn(
                                "http2 dispatch failed: {s}",
                                .{@errorName(err)},
                            );
                            break :blk internalErrorResponse(
                                arena,
                                self.options.limits,
                            );
                        };
                    }
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

                try self.respond(
                    connection,
                    request.stream_id,
                    request.method,
                    &response,
                    arena,
                );
            }

            connection.sendGoAway(
                last_stream_id,
                .no_error,
                "serve-complete",
            ) catch {};
        }

        fn dispatchRequest(
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

        fn respond(
            self: *@This(),
            connection: *netz.http2.runtime.Connection,
            stream_id: u31,
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

            if (response.stream) |body| {
                const body_forbidden = std.mem.eql(u8, method, "HEAD") or
                    response.status == 204 or
                    response.status == 304 or
                    (response.status >= 100 and response.status < 200);
                if (body_forbidden) {
                    body.cancel();
                    response.stream = null;
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
                    try self.writeBuffered(
                        connection,
                        stream_id,
                        method,
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
                    connection,
                    stream_id,
                    method,
                    response,
                    body,
                    arena,
                );
                return;
            }

            try self.writeBuffered(
                connection,
                stream_id,
                method,
                response,
                arena,
            );
        }

        fn writeBuffered(
            self: *@This(),
            connection: *netz.http2.runtime.Connection,
            stream_id: u31,
            method: []const u8,
            response: *Response,
            arena: std.mem.Allocator,
        ) !void {
            _ = self;
            const options = try toResponseOptions(response, method, arena);
            try connection.writeResponse(stream_id, options);
        }

        fn writeStreaming(
            self: *@This(),
            connection: *netz.http2.runtime.Connection,
            stream_id: u31,
            method: []const u8,
            response: *Response,
            body: stream_mod.Body,
            arena: std.mem.Allocator,
        ) !void {
            const headers = try headerFields(response, arena);
            var writer = connection.startResponse(stream_id, .{
                .status = response.status,
                .headers = headers,
                .request_method = method,
            }) catch |err| {
                body.cancel();
                return err;
            };
            defer writer.deinit();

            var state = Http2StreamState{
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
    };
}

fn dupeH2Headers(
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
    errdefer {
        freeH2HeaderCopy(allocator, headers[0..index]);
        allocator.free(headers);
    }
    for (fields) |field| {
        if (isPseudoHeader(field.name)) continue;
        const name = try allocator.dupe(u8, field.name);
        const value = allocator.dupe(u8, field.value) catch |err| {
            allocator.free(name);
            return err;
        };
        headers[index] = .{ .name = name, .value = value };
        index += 1;
    }
    if (add_host) {
        const name = try allocator.dupe(u8, "Host");
        const value = allocator.dupe(u8, authority.?) catch |err| {
            allocator.free(name);
            return err;
        };
        headers[index] = .{ .name = name, .value = value };
        index += 1;
    }
    return headers;
}

fn freeH2HeaderCopy(
    allocator: std.mem.Allocator,
    headers: []const netz.http1.Header,
) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
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

fn dispatchReplayH2(
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
    return server.dispatchRequest(request, client_info, arena, &replay);
}

fn H2StreamingRead(comptime H: type) type {
    return struct {
        const Self = @This();

        server: *Http2Server(H),
        connection: *netz.http2.runtime.Connection,
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
        fallback_streaming: bool = false,

        fn onHead(
            self: *Self,
            head: netz.streaming.http2.RequestHead,
        ) !void {
            const method = netz.http1.Method.parse(head.method) catch return;
            const target = if (head.path.len == 0) "/" else head.path;
            if (!self.server.app_router.isStreaming(method, target)) return;

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

            headers = try dupeH2Headers(
                self.allocator,
                head.headers,
                head.authority,
            );
            target_copy = try self.allocator.dupe(u8, target);

            self.reader = reader.?;
            self.headers = headers.?;
            self.target = target_copy.?;
            self.request = .{
                .method = method,
                .target = target_copy.?,
                .version = .http_1_1,
                .headers = headers.?,
                .body = "",
                .consumed = 0,
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
            const next_total = std.math.add(
                usize,
                self.body.items.len,
                chunk.len,
            ) catch return error.BodyTooLarge;
            if (next_total > self.server.options.limits.max_body_bytes) {
                return error.BodyTooLarge;
            }
            try self.body.appendSlice(self.allocator, chunk);
        }

        fn run(self: *Self) anyerror!Response {
            const reader = self.reader orelse
                return error.InvalidStreamingState;
            defer reader.drain();
            return self.server.dispatchRequest(
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
                freeH2HeaderCopy(self.allocator, headers);
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

fn toResponseOptions(
    response: *Response,
    method: []const u8,
    arena: std.mem.Allocator,
) !netz.http2.runtime.ResponseOptions {
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
