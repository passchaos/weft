const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const query_mod = @import("query.zig");

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
};

const Disposition = union(enum) {
    not_found,
    bad_request,
    method_not_allowed: router_mod.AllowedMethods,
};

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
        netz_server: netz.http1.runtime.Server,
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

            var netz_server = try netz.http1.runtime.Server.listen(
                allocator,
                io,
                options.address,
                options.limits.toNetz(),
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

            group.await(self.io) catch |err| {
                group.cancel(self.io);
                group_finished = true;
                return err;
            };
            group_finished = true;
        }

        fn worker(self: *@This()) std.Io.Cancelable!void {
            while (true) {
                if (self.shutdown.isSet()) return;

                var connection = self.netz_server.acceptWithTimeout(
                    self.options.accept_poll_interval,
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

                var response = self.dispatch(
                    &request.request,
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
                try connection.writeResponse(response.toOptionsFor(
                    request.request.method,
                    request.request.version,
                ));

                if (!keep_alive) return;
            }
        }

        fn dispatch(
            self: *@This(),
            request: *const netz.http1.Request,
            arena: std.mem.Allocator,
        ) !Response {
            const target = request.target;
            const query_index = std.mem.indexOfScalar(u8, target, '?');
            const path = if (query_index) |index| target[0..index] else target;
            const query = if (query_index) |index| target[index + 1 ..] else "";

            const resolution = try self.app_router.resolve(
                request.method,
                path,
                arena,
            );

            var disposition: ?Disposition = null;
            var query_params: []const query_mod.Pair = &.{};
            var params: []const ctx_mod.Param = &.{};
            var route_middleware: []const Handler = &.{};
            var final_handler: Handler = ctx_mod.handler(respondDisposition);

            const parsed_query = query_mod.parse(
                arena,
                query,
                self.options.limits.max_query_params,
            ) catch blk: {
                disposition = .bad_request;
                break :blk query_mod.Query{};
            };
            query_params = parsed_query.pairs;

            switch (resolution) {
                .matched => |matched| {
                    if (disposition == null) {
                        if (decodeParams(arena, matched.params) catch null) |decoded| {
                            params = decoded;
                            route_middleware = matched.route.middleware;
                            final_handler = matched.route.handler;
                        } else {
                            disposition = .bad_request;
                        }
                    }
                },
                .method_not_allowed => |allowed| {
                    if (disposition == null) {
                        disposition = .{ .method_not_allowed = allowed };
                    }
                },
                .not_found => {
                    if (disposition == null) disposition = .not_found;
                },
            }

            var middleware = self.options.middleware;
            if (disposition == null and route_middleware.len > 0) {
                const total = middleware.len + route_middleware.len;
                if (total > self.options.limits.max_middleware) {
                    return error.TooMuchMiddleware;
                }
                const combined = try arena.alloc(Handler, total);
                @memcpy(combined[0..middleware.len], middleware);
                @memcpy(combined[middleware.len..], route_middleware);
                middleware = combined;
            }

            var context = Ctx{
                .app = @ptrCast(&self.app),
                .io = self.io,
                .arena = arena,
                .limits = self.options.limits,
                .request = request,
                .query = query,
                .query_params = query_params,
                .params = params,
                .response = Response.initWithLimits(arena, self.options.limits),
                .middleware = middleware,
                .final_handler = final_handler,
            };

            if (disposition) |value| {
                try context.set(Disposition, value);
            }

            context.run() catch |err| {
                if (err == error.Canceled) return error.Canceled;
                std.log.scoped(.weft).warn(
                    "handler failed: {s}",
                    .{@errorName(err)},
                );
                // Nothing has reached the wire yet, so a failed handler can
                // always be replaced with a clean 500.
                context.response.reset();
                context.response.setStatus(500);
                context.response.text("Internal Server Error") catch {};
            };

            return context.response;
        }
    };
}

fn respondDisposition(ctx: *Ctx) anyerror!void {
    const disposition = ctx.get(Disposition) orelse {
        ctx.setStatus(500);
        return ctx.text("Internal Server Error");
    };

    switch (disposition) {
        .not_found => {
            ctx.setStatus(404);
            try ctx.text("Not Found");
        },
        .bad_request => {
            ctx.setStatus(400);
            try ctx.text("Bad Request");
        },
        .method_not_allowed => |allowed| {
            try ctx.setHeader("Allow", try allowed.value(ctx.arena));
            if (ctx.method() == .OPTIONS) {
                ctx.setStatus(204);
                return;
            }
            ctx.setStatus(405);
            try ctx.text("Method Not Allowed");
        },
    }
}

fn decodeParams(
    arena: std.mem.Allocator,
    raw: []const ctx_mod.Param,
) ![]const ctx_mod.Param {
    if (raw.len == 0) return &.{};
    const decoded = try arena.alloc(ctx_mod.Param, raw.len);
    for (raw, 0..) |param, index| {
        decoded[index] = .{
            .name = param.name,
            .value = try query_mod.decodeComponent(arena, param.value, false),
        };
    }
    return decoded;
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
