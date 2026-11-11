const std = @import("std");
const netz = @import("netz");
const drain_mod = @import("drain.zig");
const logging_mod = @import("logging.zig");

pub const Status = netz.grpc.Status;
pub const Timeout = netz.grpc.Timeout;
pub const CompressionAlgorithm = netz.grpc.CompressionAlgorithm;
pub const CompressionAlgorithmSet = netz.grpc.CompressionAlgorithmSet;

pub const Options = struct {
    address: std.Io.net.IpAddress,
    limits: netz.http2.runtime.Limits = .{},
    /// Non-null selects a TLS/ALPN `h2` listener. Null uses cleartext h2c.
    tls: ?netz.http2.runtime.TlsListenOptions = null,
    max_message_size: usize = 4 * 1024 * 1024,
    max_connections: usize = 64,
    max_requests_per_connection: usize = 1000,
    accept_timeout: std.Io.Duration = .fromMilliseconds(500),
    accept_error_backoff: std.Io.Duration = .fromMilliseconds(10),
    idle_timeout: std.Io.Duration = .fromSeconds(60),
    drain_timeout: ?std.Io.Duration = .fromSeconds(5),
};

/// One unary gRPC call.
///
/// `message` is the decoded application payload. Protobuf encoding and
/// decoding stay in the application or in `netz.grpc.pbz`.
pub const Context = struct {
    connection: *netz.grpc.runtime.ServerConnection,
    stream_id: u31,
    path: []const u8,
    service: []const u8,
    method: []const u8,
    message: []const u8,
    headers: []const netz.http2.Hpack.HeaderField,
    timeout: ?Timeout,
    accepted_encodings: CompressionAlgorithmSet,
    max_message_size: usize,
    responded: bool = false,

    pub fn respond(self: *Context, message: []const u8) !void {
        if (message.len > self.max_message_size) return error.MessageTooLarge;
        try self.respondWithOptions(.{
            .message = message,
            .request_accepted_encodings = self.accepted_encodings,
        });
    }

    pub fn respondWithOptions(
        self: *Context,
        options: netz.grpc.UnaryResponseOptions,
    ) !void {
        if (self.responded) return error.AlreadyResponded;
        var value = options;
        value.request_accepted_encodings = self.accepted_encodings;
        try self.connection.writeUnary(self.stream_id, value);
        self.responded = true;
    }

    /// Finish the call with a non-OK status and no response message.
    pub fn respondStatus(
        self: *Context,
        status: Status,
        status_message: ?[]const u8,
    ) !void {
        if (self.responded) return error.AlreadyResponded;
        try self.connection.writeUnary(self.stream_id, .{
            .status = status,
            .status_message = status_message,
            .trailers_only = true,
            .accepted_encodings = self.accepted_encodings,
        });
        self.responded = true;
    }

    pub fn header(self: *const Context, name: []const u8) ?[]const u8 {
        for (self.headers) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, name)) return field.value;
        }
        return null;
    }
};

/// Unary gRPC server adapter over netz's HTTP/2 runtime.
///
/// Routes are exact gRPC method paths such as `/demo.Echo/Unary`. Streaming
/// RPCs remain available through netz's `ServerConnection` APIs; this adapter
/// intentionally exposes the unary path used by most services.
pub fn GrpcServer(comptime H: type) type {
    comptime {
        if (H == void) {
            @compileError(
                "weft.GrpcServer requires a non-void app context; use an empty struct",
            );
        }
    }
    return struct {
        const Self = @This();

        pub const Handler = *const fn (*H, *Context) anyerror!void;

        const Transport = union(enum) {
            cleartext: netz.grpc.runtime.Server,
            tls: netz.grpc.runtime.TlsServer,
        };

        io: std.Io,
        allocator: std.mem.Allocator,
        app: H,
        options: Options,
        transport: Transport,
        routes: std.StringHashMapUnmanaged(Handler) = .empty,
        fallback_handler: ?Handler = null,
        shutdown: std.Io.Event = .unset,

        pub fn init(
            io: std.Io,
            allocator: std.mem.Allocator,
            options: Options,
            app: H,
        ) !Self {
            if (options.max_connections == 0 or
                options.max_requests_per_connection == 0 or
                options.max_message_size == 0 or
                options.accept_timeout.nanoseconds <= 0 or
                options.accept_error_backoff.nanoseconds <= 0 or
                options.idle_timeout.nanoseconds <= 0 or
                (options.drain_timeout != null and
                    options.drain_timeout.?.nanoseconds <= 0))
            {
                return error.InvalidOptions;
            }
            const transport: Transport = if (options.tls) |tls| .{
                .tls = try netz.grpc.runtime.TlsServer.listen(
                    allocator,
                    io,
                    options.address,
                    .{
                        .transport = tls,
                        .max_message_size = options.max_message_size,
                    },
                ),
            } else .{
                .cleartext = try netz.grpc.runtime.Server.listenWithOptions(
                    allocator,
                    io,
                    options.address,
                    .{
                        .limits = options.limits,
                        .max_message_size = options.max_message_size,
                    },
                ),
            };
            return .{
                .io = io,
                .allocator = allocator,
                .app = app,
                .options = options,
                .transport = transport,
            };
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.routes.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.routes.deinit(self.allocator);
            switch (self.transport) {
                .cleartext => |*server| server.deinit(),
                .tls => |*server| server.deinit(),
            }
            self.* = undefined;
        }

        pub fn address(self: *const Self) std.Io.net.IpAddress {
            return switch (self.transport) {
                .cleartext => |server| server.address(),
                .tls => |server| server.address(),
            };
        }

        pub fn route(
            self: *Self,
            path: []const u8,
            handler: Handler,
        ) !void {
            if (path.len == 0 or path[0] != '/') return error.InvalidPath;
            if (self.routes.contains(path)) return error.DuplicateRoute;
            const owned = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned);
            try self.routes.put(self.allocator, owned, handler);
        }

        pub fn setFallback(self: *Self, handler: Handler) void {
            self.fallback_handler = handler;
        }

        pub fn stop(self: *Self) void {
            self.shutdown.set(self.io);
        }

        pub fn serve(self: *Self) !void {
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

        fn acceptWithTimeout(
            self: *Self,
            timeout: std.Io.Duration,
        ) !netz.grpc.runtime.ServerConnection {
            return switch (self.transport) {
                .cleartext => |*server| server.acceptWithTimeout(timeout),
                .tls => |*server| server.acceptWithTimeout(timeout),
            };
        }

        fn acceptWorker(
            self: *Self,
            group: *std.Io.Group,
            semaphore: *std.Io.Semaphore,
        ) std.Io.Cancelable!void {
            while (true) {
                if (self.shutdown.isSet()) return;
                try semaphore.wait(self.io);

                const connection = self.acceptWithTimeout(
                    self.options.accept_timeout,
                ) catch |err| {
                    semaphore.post(self.io);
                    if (err == error.Canceled) return error.Canceled;
                    if (err == error.Timeout) continue;
                    if (self.shutdown.isSet()) return;
                    logging_mod.logWarn(
                        "weft",
                        "grpc accept failed: {s}",
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

                group.async(self.io, connectionWorker, .{
                    self,
                    connection,
                    semaphore,
                });
            }
        }

        fn connectionWorker(
            self: *Self,
            connection: netz.grpc.runtime.ServerConnection,
            semaphore: *std.Io.Semaphore,
        ) std.Io.Cancelable!void {
            var owned = connection;
            defer {
                owned.deinit();
                semaphore.post(self.io);
            }

            var served: usize = 0;
            while (served < self.options.max_requests_per_connection) {
                var request = owned.readUnaryWithTimeout(
                    self.options.idle_timeout,
                ) catch |err| switch (err) {
                    error.Timeout,
                    error.ConnectionClosed,
                    error.Canceled,
                    => return,
                    else => {
                        logging_mod.logWarn(
                            "weft",
                            "grpc connection failed: {s}",
                            .{@errorName(err)},
                            .{ .err = @errorName(err) },
                        );
                        return;
                    },
                };
                defer request.deinit();
                served += 1;

                const handler = self.routes.get(request.request.path) orelse
                    self.fallback_handler orelse {
                    owned.writeUnary(request.request.stream_id, .{
                        .status = .unimplemented,
                        .status_message = "Method not found",
                        .trailers_only = true,
                    }) catch {};
                    continue;
                };

                var context = Context{
                    .connection = &owned,
                    .stream_id = request.request.stream_id,
                    .path = request.request.path,
                    .service = request.request.service,
                    .method = request.request.method,
                    .message = request.request.message.payload,
                    .headers = request.request.headers,
                    .timeout = request.request.timeout,
                    .accepted_encodings = request.request.accepted_encodings,
                    .max_message_size = self.options.max_message_size,
                };
                handler(&self.app, &context) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    if (!context.responded) {
                        owned.writeUnary(request.request.stream_id, .{
                            .status = .internal,
                            .status_message = "Handler failed",
                            .trailers_only = true,
                        }) catch {};
                    }
                    continue;
                };
                if (!context.responded) {
                    owned.writeUnary(request.request.stream_id, .{
                        .status = .internal,
                        .status_message = "Handler did not respond",
                        .trailers_only = true,
                    }) catch {};
                }
            }

            owned.gracefulShutdownWithTimeout(.fromSeconds(1)) catch {};
        }
    };
}
