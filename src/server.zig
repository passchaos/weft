const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");

pub const Ctx = ctx_mod.Ctx;
pub const Handler = ctx_mod.Handler;
pub const Response = response_mod.Response;
pub const Limits = limits_mod.Limits;
pub const Router = router_mod.Router;
pub const RouteOptions = router_mod.RouteOptions;

pub const Options = struct {
    address: std.Io.net.IpAddress,
    limits: Limits = .{},
    /// Number of connection workers. Each worker owns at most one live
    /// connection at a time, so this is the effective concurrent-connection
    /// bound.
    max_connections: usize = 256,
    max_requests_per_connection: usize = 1000,
    accept_error_backoff: std.Io.Duration = .fromMilliseconds(10),
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
                options.limits.max_head_bytes == 0 or
                options.limits.max_body_bytes == 0 or
                options.limits.max_request_arena_bytes == 0 or
                options.limits.max_response_bytes == 0)
            {
                return error.InvalidOptions;
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
                .app_router = router_mod.Router(H).init(allocator),
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

        /// Request shutdown. Pending accepts are cancelled; in-flight requests
        /// may be interrupted by cancellation.
        pub fn stop(self: *@This()) void {
            self.shutdown.set(self.io);
        }

        /// Serve until `stop` is called or the serving task is cancelled.
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
            group.cancel(self.io);
            group_finished = true;
        }

        fn worker(self: *@This()) std.Io.Cancelable!void {
            while (!self.shutdown.isSet()) {
                var connection = self.netz_server.accept() catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    if (self.shutdown.isSet()) return;
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
                if (self.shutdown.isSet()) {
                    connection.gracefulShutdown();
                }

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
                    std.log.scoped(.weft).warn(
                        "dispatch failed: {s}",
                        .{@errorName(err)},
                    );
                    var fallback = Response.init(
                        arena,
                        self.options.limits.max_response_bytes,
                    );
                    fallback.setStatus(500);
                    fallback.text("Internal Server Error") catch {};
                    break :blk fallback;
                };

                if (response.body.len > self.options.limits.max_response_bytes) {
                    response.setStatus(500);
                    response.text("Response Too Large") catch {};
                }

                try connection.writeResponse(
                    response.toOptions(request.request.method),
                );

                if (!request.request.keepAlive()) return;
                if (self.shutdown.isSet()) return;
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

            var matched = (try self.app_router.match(
                request.method,
                path,
                arena,
            )) orelse {
                var not_found = Response.init(
                    arena,
                    self.options.limits.max_response_bytes,
                );
                not_found.setStatus(404);
                try not_found.text("Not Found");
                return not_found;
            };
            matched.query = query;

            var context = Ctx{
                .app = @ptrCast(&self.app),
                .io = self.io,
                .arena = arena,
                .limits = self.options.limits,
                .request = request,
                .query = query,
                .params = matched.params,
                .response = Response.init(
                    arena,
                    self.options.limits.max_response_bytes,
                ),
                .middleware = matched.route.middleware,
                .final_handler = matched.route.handler,
            };

            context.run() catch |err| {
                if (!context.response.committed) {
                    context.response.setStatus(500);
                    context.response.text("Internal Server Error") catch {};
                }
                std.log.scoped(.weft).warn(
                    "handler failed: {s}",
                    .{@errorName(err)},
                );
            };

            return context.response;
        }
    };
}

fn statusForReadError(err: anyerror) ?u16 {
    if (err == error.HeadersTooLarge or err == error.TooManyHeaders) {
        return 431;
    }
    if (err == error.UriTooLong) return 414;
    if (err == error.BodyTooLarge) return 413;
    if (err == error.MalformedStartLine or
        err == error.MalformedHeader or
        err == error.InvalidMethod or
        err == error.InvalidVersion or
        err == error.InvalidHost)
    {
        return 400;
    }
    return null;
}
