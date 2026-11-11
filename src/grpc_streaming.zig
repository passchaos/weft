const std = @import("std");
const netz = @import("netz");
const drain_mod = @import("drain.zig");
const logging_mod = @import("logging.zig");
const grpc_mod = @import("grpc.zig");

pub const Status = netz.grpc.Status;
pub const Timeout = netz.grpc.Timeout;
pub const CompressionAlgorithmSet = netz.grpc.CompressionAlgorithmSet;
pub const Options = grpc_mod.Options;

/// One streaming RPC.
///
/// Request messages are collected before the handler runs. The handler may
/// write zero or more response messages and must finish the call. This covers
/// client-streaming and server-streaming RPCs; interleaved bidirectional
/// handlers should use netz's `ServerDuplex` directly.
pub const Context = struct {
    stream: *netz.grpc.stream.ServerDuplex,
    path: []const u8,
    service: []const u8,
    method: []const u8,
    headers: []const netz.http2.Hpack.HeaderField,
    timeout: ?Timeout,
    accepted_encodings: CompressionAlgorithmSet,
    max_message_size: usize,
    messages: []const []const u8,
    message_index: usize = 0,
    started: bool = false,
    finished: bool = false,

    pub fn nextMessage(self: *Context) ?[]const u8 {
        if (self.message_index >= self.messages.len) return null;
        const message = self.messages[self.message_index];
        self.message_index += 1;
        return message;
    }

    pub fn start(self: *Context) !void {
        if (self.started) return;
        try self.stream.startResponse(.{
            .max_message_size = self.max_message_size,
            .request_accepted_encodings = self.accepted_encodings,
        });
        self.started = true;
    }

    pub fn write(self: *Context, message: []const u8) !void {
        if (message.len > self.max_message_size) return error.MessageTooLarge;
        try self.start();
        _ = try self.stream.writeMessage(message);
    }

    pub fn finish(
        self: *Context,
        status: Status,
        status_message: ?[]const u8,
    ) !void {
        if (self.finished) return;
        try self.stream.finish(status, status_message, &.{}, &.{});
        self.finished = true;
    }
};

/// Streaming gRPC server adapter over netz's HTTP/2 duplex runtime.
pub fn GrpcStreamingServer(comptime H: type) type {
    comptime {
        if (H == void) {
            @compileError(
                "weft.GrpcStreamingServer requires a non-void app context; use an empty struct",
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
                        "grpc streaming accept failed: {s}",
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
                var stream = owned.acceptDuplexWithTimeout(
                    self.options.idle_timeout,
                ) catch |err| switch (err) {
                    error.Timeout,
                    error.ConnectionClosed,
                    error.Canceled,
                    => return,
                    else => {
                        logging_mod.logWarn(
                            "weft",
                            "grpc streaming connection failed: {s}",
                            .{@errorName(err)},
                            .{ .err = @errorName(err) },
                        );
                        return;
                    },
                };
                defer stream.deinit();
                served += 1;

                const handler = self.routes.get(stream.path) orelse
                    self.fallback_handler orelse {
                    stream.finish(
                        .unimplemented,
                        "Method not found",
                        &.{},
                        &.{},
                    ) catch {};
                    continue;
                };

                var messages: std.ArrayListUnmanaged([]u8) = .empty;
                defer {
                    for (messages.items) |message| {
                        self.allocator.free(message);
                    }
                    messages.deinit(self.allocator);
                }
                var collector = Collector{
                    .allocator = self.allocator,
                    .messages = &messages,
                };
                const read_ok = readRequestMessages(
                    &stream,
                    &collector,
                    self.options.idle_timeout,
                ) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => false,
                };
                if (!read_ok) {
                    stream.finish(
                        .invalid_argument,
                        "Invalid streaming request",
                        &.{},
                        &.{},
                    ) catch {};
                    continue;
                }

                var context = Context{
                    .stream = &stream,
                    .path = stream.path,
                    .service = stream.service,
                    .method = stream.method,
                    .headers = stream.requestHeaders(),
                    .timeout = stream.timeout,
                    .accepted_encodings = stream.accepted_encodings,
                    .max_message_size = self.options.max_message_size,
                    .messages = messages.items,
                };
                handler(&self.app, &context) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    if (!context.finished) {
                        stream.finish(
                            .internal,
                            "Handler failed",
                            &.{},
                            &.{},
                        ) catch {};
                    }
                    continue;
                };
                if (!context.finished) {
                    stream.finish(
                        .internal,
                        "Handler did not finish",
                        &.{},
                        &.{},
                    ) catch {};
                }
            }

            owned.gracefulShutdownWithTimeout(.fromSeconds(1)) catch {};
        }
    };
}

const Collector = struct {
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged([]u8),

    fn consume(self: *Collector, message: netz.grpc.StreamingMessage) !void {
        const copy = try self.allocator.dupe(u8, message.payload);
        errdefer self.allocator.free(copy);
        try self.messages.append(self.allocator, copy);
    }
};

fn readRequestMessages(
    stream: *netz.grpc.stream.ServerDuplex,
    collector: *Collector,
    idle_timeout: std.Io.Duration,
) !bool {
    while (true) {
        var event = try stream.readRequestEventWithTimeout(
            idle_timeout,
            collector,
            Collector.consume,
        );
        defer event.deinit();
        switch (event) {
            .messages => |progress| {
                if (progress.end_stream) return true;
            },
            .finished => return true,
            .reset => return false,
        }
    }
}
