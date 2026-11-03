const std = @import("std");
const netz = @import("netz");
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
            const client_info = ctx_mod.ClientInfo{
                .address = connection.stream.socket.address,
                .protocol = .http_2,
                .tls = self.options.tls != null,
            };

            while (served < self.options.max_requests_per_connection) : (served += 1) {
                if (self.shutdown.isSet()) {
                    connection.sendGoAway(
                        last_stream_id,
                        .no_error,
                        "shutdown",
                    ) catch {};
                    return;
                }

                var stream = connection.acceptDuplexRequestWithTimeout(
                    self.options.idle_timeout,
                ) catch |err| {
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
                defer stream.deinit();
                last_stream_id = stream.stream_id;

                var fixed_arena = std.heap.FixedBufferAllocator.init(
                    arena_buffer,
                );
                const arena = fixed_arena.allocator();

                const method = netz.http1.Method.parse(stream.method) catch {
                    stream.reset(.protocol_error) catch {};
                    continue;
                };
                const target = if (stream.path.len == 0) "/" else stream.path;
                const headers = convertH2Headers(
                    arena,
                    stream.headers,
                    stream.authority,
                ) catch {
                    stream.reset(.internal_error) catch {};
                    continue;
                };

                var body: std.ArrayListUnmanaged(u8) = .empty;
                defer body.deinit(self.allocator);
                const streaming = self.app_router.isStreaming(method, target);
                var body_reader: ?ctx_mod.BodyReader = null;

                var body_failed = false;
                if (streaming) {
                    body_reader = .{ .duplex = &stream };
                } else {
                    while (true) {
                        const chunk = stream.nextBody() catch {
                            stream.reset(.cancel) catch {};
                            body_failed = true;
                            break;
                        };
                        if (chunk == null) break;
                        const next_total = std.math.add(
                            usize,
                            body.items.len,
                            chunk.?.len,
                        ) catch {
                            stream.reset(.cancel) catch {};
                            body_failed = true;
                            break;
                        };
                        if (next_total > self.options.limits.max_body_bytes) {
                            stream.reset(.cancel) catch {};
                            body_failed = true;
                            break;
                        }
                        body.appendSlice(self.allocator, chunk.?) catch {
                            stream.reset(.internal_error) catch {};
                            body_failed = true;
                            break;
                        };
                    }
                }
                if (body_failed) continue;

                var trailers = try arena.alloc(netz.http1.Header, 0);
                if (!streaming) {
                    if (stream.requestTrailers()) |raw| {
                        trailers = convertH2Trailers(arena, raw) catch trailers;
                    }
                }
                var handler_request = netz.http1.Request{
                    .method = method,
                    .target = target,
                    .version = .http_1_1,
                    .headers = headers,
                    .body = if (streaming) "" else body.items,
                    .trailers = trailers,
                    .consumed = 0,
                    .must_close = false,
                };

                var response = self.dispatchRequest(
                    &handler_request,
                    client_info,
                    arena,
                    body_reader,
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

                if (streaming and !stream.requestFinished()) {
                    var drain_failed = false;
                    while (true) {
                        const chunk = stream.nextBody() catch {
                            drain_failed = true;
                            break;
                        };
                        if (chunk == null) break;
                    }
                    if (drain_failed) {
                        stream.reset(.cancel) catch {};
                        continue;
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

                self.respondDuplex(
                    &stream,
                    stream.method,
                    &response,
                    arena,
                ) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    std.log.scoped(.weft).warn(
                        "http2 response failed: {s}",
                        .{@errorName(err)},
                    );
                    stream.reset(.internal_error) catch {};
                    continue;
                };
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
                body_reader,
            );
        }

        fn respondDuplex(
            self: *@This(),
            stream: *netz.http2.runtime.ServerDuplexStream,
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
            }

            const headers = try headerFields(response, arena);
            try stream.startResponse(.{
                .status = response.status,
                .headers = headers,
                .request_method = method,
            });

            if (body_forbidden) {
                _ = try stream.finishResponse();
                return;
            }

            if (response.stream) |body| {
                var state = H2DuplexState{
                    .stream = stream,
                    .remaining = body.length orelse
                        self.options.limits.max_response_bytes,
                };
                var writer = stream_mod.Writer{
                    .context = &state,
                    .write_fn = writeDuplexWithBudget,
                };
                body.run(&writer) catch |err| {
                    body.cancel();
                    stream.reset(.internal_error) catch {};
                    return err;
                };
                _ = try stream.finishResponse();
                response.stream = null;
                return;
            }

            _ = try stream.finishResponseData(response.body);
        }
    };
}

const H2DuplexState = struct {
    stream: *netz.http2.runtime.ServerDuplexStream,
    remaining: usize,
};

fn writeDuplexWithBudget(raw: ?*anyopaque, data: []const u8) anyerror!void {
    const state: *H2DuplexState = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    if (data.len > state.remaining) return error.ResponseTooLarge;
    state.remaining -= data.len;
    _ = try state.stream.writeResponse(data);
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
