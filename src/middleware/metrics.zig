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
