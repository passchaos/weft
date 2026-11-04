const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const errors_mod = @import("../errors.zig");

/// Lock-free request counters and latency totals.
///
/// The middleware is allocation-free after construction. Counters use
/// monotonic atomics, so a snapshot is a best-effort view under concurrent
/// requests rather than a transactionally consistent one.
pub const Metrics = struct {
    total: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(u64) = .init(0),
    status_2xx: std.atomic.Value(u64) = .init(0),
    status_3xx: std.atomic.Value(u64) = .init(0),
    status_4xx: std.atomic.Value(u64) = .init(0),
    status_5xx: std.atomic.Value(u64) = .init(0),
    total_latency_ns: std.atomic.Value(u64) = .init(0),

    pub const Snapshot = struct {
        total: u64,
        active: u64,
        status_2xx: u64,
        status_3xx: u64,
        status_4xx: u64,
        status_5xx: u64,
        total_latency_ns: u64,

        pub fn averageLatencyNs(self: Snapshot) u64 {
            if (self.total == 0) return 0;
            return self.total_latency_ns / self.total;
        }

        /// Render this snapshot in the Prometheus text exposition format.
        /// `namespace` must match `[a-zA-Z_][a-zA-Z0-9_]*`; an invalid prefix is
        /// rejected so app configuration cannot inject arbitrary exposition
        /// lines. Serve the result with
        /// `Content-Type: text/plain; version=0.0.4; charset=utf-8`.
        pub fn writePrometheus(
            self: Snapshot,
            writer: *std.Io.Writer,
            namespace: []const u8,
        ) !void {
            if (!validNamespace(namespace)) return error.InvalidNamespace;
            try writer.print(
                "# HELP {s}_requests_total Total requests handled.\n" ++
                    "# TYPE {s}_requests_total counter\n" ++
                    "{s}_requests_total {d}\n",
                .{ namespace, namespace, namespace, self.total },
            );
            try writer.print(
                "# HELP {s}_requests_active Requests currently in flight.\n" ++
                    "# TYPE {s}_requests_active gauge\n" ++
                    "{s}_requests_active {d}\n",
                .{ namespace, namespace, namespace, self.active },
            );
            inline for (.{
                .{ "2xx", self.status_2xx },
                .{ "3xx", self.status_3xx },
                .{ "4xx", self.status_4xx },
                .{ "5xx", self.status_5xx },
            }) |entry| {
                try writer.print(
                    "{s}_responses_total{{status_class=\"{s}\"}} {d}\n",
                    .{ namespace, entry[0], entry[1] },
                );
            }
            try writer.print(
                "# HELP {s}_request_duration_nanoseconds_sum Total time spent in\n" ++
                    "# TYPE {s}_request_duration_nanoseconds_sum counter\n" ++
                    "{s}_request_duration_nanoseconds_sum {d}\n",
                .{
                    namespace,
                    namespace,
                    namespace,
                    self.total_latency_ns,
                },
            );
            try writer.print(
                "# HELP {s}_request_duration_nanoseconds_count Requests measured.\n" ++
                    "# TYPE {s}_request_duration_nanoseconds_count counter\n" ++
                    "{s}_request_duration_nanoseconds_count {d}\n",
                .{ namespace, namespace, namespace, self.total },
            );
        }
    };

    pub fn handler(self: *Metrics) ctx_mod.Handler {
        return ctx_mod.withContext(Metrics, self, call);
    }

    pub fn snapshot(self: *const Metrics) Snapshot {
        return .{
            .total = self.total.load(.monotonic),
            .active = self.active.load(.monotonic),
            .status_2xx = self.status_2xx.load(.monotonic),
            .status_3xx = self.status_3xx.load(.monotonic),
            .status_4xx = self.status_4xx.load(.monotonic),
            .status_5xx = self.status_5xx.load(.monotonic),
            .total_latency_ns = self.total_latency_ns.load(.monotonic),
        };
    }

    fn call(self: *Metrics, ctx: *ctx_mod.Ctx) anyerror!void {
        const started = std.Io.Timestamp.now(ctx.io, .awake);
        _ = self.active.fetchAdd(1, .monotonic);
        var failure: ?anyerror = null;
        defer {
            _ = self.active.fetchSub(1, .monotonic);
            _ = self.total.fetchAdd(1, .monotonic);

            const elapsed = started.untilNow(ctx.io, .awake).nanoseconds;
            if (elapsed > 0) {
                _ = self.total_latency_ns.fetchAdd(
                    @intCast(elapsed),
                    .monotonic,
                );
            }

            // Classify handler errors the same way dispatch will, so a
            // malformed JSON body counts as 4xx rather than 5xx. Canceled
            // requests never reach the wire and are excluded from status
            // classes.
            const status: ?u16 = if (failure) |err| blk: {
                if (err == error.Canceled) break :blk null;
                break :blk errors_mod.statusForHandlerError(err);
            } else ctx.response.status;
            if (status) |value| switch (value) {
                200...299 => _ = self.status_2xx.fetchAdd(1, .monotonic),
                300...399 => _ = self.status_3xx.fetchAdd(1, .monotonic),
                400...499 => _ = self.status_4xx.fetchAdd(1, .monotonic),
                500...599 => _ = self.status_5xx.fetchAdd(1, .monotonic),
                else => {},
            };
        }

        ctx.next() catch |err| {
            failure = err;
            return err;
        };
    }
};

/// Apply the default metrics middleware.
pub fn metrics(ctx: *ctx_mod.Ctx) anyerror!void {
    var defaults = Metrics{};
    return defaults.call(ctx);
}

test "metrics counts active, total, and status classes" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var counters = Metrics{};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var ok_context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{counters.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };
    try ok_context.run();

    var missing_context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{counters.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                ctx.setStatus(404);
                try ctx.text("missing");
            }
        }.handle),
    };
    try missing_context.run();

    const snapshot = counters.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snapshot.total);
    try std.testing.expectEqual(@as(u64, 0), snapshot.active);
    try std.testing.expectEqual(@as(u64, 1), snapshot.status_2xx);
    try std.testing.expectEqual(@as(u64, 1), snapshot.status_4xx);
    try std.testing.expectEqual(@as(u64, 0), snapshot.status_5xx);
}

test "metrics classify handler errors like dispatch" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var counters = Metrics{};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var bad_context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{counters.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(_: *ctx_mod.Ctx) anyerror!void {
                return error.InvalidJson;
            }
        }.handle),
    };
    bad_context.run() catch {};

    var canceled_context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{counters.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(_: *ctx_mod.Ctx) anyerror!void {
                return error.Canceled;
            }
        }.handle),
    };
    canceled_context.run() catch {};

    const snapshot = counters.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snapshot.total);
    try std.testing.expectEqual(@as(u64, 1), snapshot.status_4xx);
    try std.testing.expectEqual(@as(u64, 0), snapshot.status_5xx);
}

fn validNamespace(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value, 0..) |byte, index| {
        const alpha = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            byte == '_';
        if (index == 0) {
            if (!alpha) return false;
            continue;
        }
        if (!alpha and !(byte >= '0' and byte <= '9')) return false;
    }
    return true;
}

test "prometheus exposition renders counters and rejects bad namespaces" {
    const snapshot = Metrics.Snapshot{
        .total = 5,
        .active = 2,
        .status_2xx = 3,
        .status_3xx = 0,
        .status_4xx = 1,
        .status_5xx = 1,
        .total_latency_ns = 5000,
    };
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try snapshot.writePrometheus(&writer, "weft");
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "weft_requests_total 5",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "weft_responses_total{status_class=\"4xx\"} 1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "weft_request_duration_nanoseconds_sum 5000",
    ) != null);

    try std.testing.expectError(
        error.InvalidNamespace,
        snapshot.writePrometheus(&writer, "bad-name"),
    );
    try std.testing.expectError(
        error.InvalidNamespace,
        snapshot.writePrometheus(&writer, ""),
    );
}
