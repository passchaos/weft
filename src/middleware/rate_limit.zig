const std = @import("std");
const ctx_mod = @import("../ctx.zig");

/// Bounded per-client token bucket rate limiter.
///
/// Clients are keyed by `Ctx.clientAddress()`. When an adapter cannot provide
/// an address, all such requests share one bucket. Bucket storage is fixed at
/// construction and evicts the least-recently-seen client when full.
///
/// Rate limiting uses the direct peer address. Applications behind a reverse
/// proxy must apply their own trusted-proxy policy before enabling this.
pub const RateLimit = struct {
    allocator: std.mem.Allocator,
    max_requests: u64,
    window_ns: i96,
    buckets: []Bucket,
    mutex: std.Io.Mutex = .init,
    global_bucket: Bucket = .{},

    pub const Options = struct {
        max_requests: usize = 100,
        window: std.Io.Duration = .fromSeconds(1),
        max_clients: usize = 4096,
    };

    const Bucket = struct {
        address: ?std.Io.net.IpAddress = null,
        used: bool = false,
        tokens: u64 = 0,
        last_refill_ns: i96 = 0,
        last_seen_ns: i96 = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        options: Options,
    ) !RateLimit {
        if (options.max_requests == 0 or
            options.window.nanoseconds <= 0 or
            options.max_clients == 0)
        {
            return error.InvalidOptions;
        }

        const buckets = try allocator.alloc(Bucket, options.max_clients);
        for (buckets) |*bucket| bucket.* = .{};

        return .{
            .allocator = allocator,
            .max_requests = options.max_requests,
            .window_ns = options.window.nanoseconds,
            .buckets = buckets,
        };
    }

    pub fn deinit(self: *RateLimit) void {
        self.allocator.free(self.buckets);
        self.* = undefined;
    }

    pub fn handler(self: *RateLimit) ctx_mod.Handler {
        return ctx_mod.withContext(RateLimit, self, call);
    }

    fn call(self: *RateLimit, ctx: *ctx_mod.Ctx) anyerror!void {
        const address = ctx.clientAddress();
        const now = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds;

        var limited = false;
        var retry_after: u64 = 1;
        try self.mutex.lock(ctx.io);
        {
            defer self.mutex.unlock(ctx.io);

            const bucket = self.bucketFor(address, now);
            self.refill(bucket, now);
            bucket.last_seen_ns = now;
            if (bucket.tokens == 0) {
                limited = true;
                retry_after = self.retryAfter(bucket, now);
            } else {
                bucket.tokens -= 1;
            }
        }

        if (limited) {
            ctx.setStatus(429);
            try ctx.setHeader(
                "Retry-After",
                try std.fmt.allocPrint(ctx.arena, "{d}", .{retry_after}),
            );
            try ctx.text("Too Many Requests");
            return;
        }

        try ctx.next();
    }

    fn bucketFor(
        self: *RateLimit,
        address: ?std.Io.net.IpAddress,
        now: i96,
    ) *Bucket {
        if (address == null) {
            if (!self.global_bucket.used) {
                self.global_bucket = .{
                    .used = true,
                    .tokens = self.max_requests,
                    .last_refill_ns = now,
                    .last_seen_ns = now,
                };
            }
            return &self.global_bucket;
        }

        for (self.buckets) |*bucket| {
            if (!bucket.used) continue;
            if (bucket.address != null and
                std.meta.eql(bucket.address.?, address.?))
            {
                return bucket;
            }
        }

        var victim: *Bucket = &self.buckets[0];
        for (self.buckets) |*bucket| {
            if (!bucket.used) {
                victim = bucket;
                break;
            }
            if (bucket.last_seen_ns < victim.last_seen_ns) victim = bucket;
        }
        victim.* = .{
            .address = address,
            .used = true,
            .tokens = self.max_requests,
            .last_refill_ns = now,
            .last_seen_ns = now,
        };
        return victim;
    }

    fn refill(self: *RateLimit, bucket: *Bucket, now: i96) void {
        const elapsed = now - bucket.last_refill_ns;
        if (elapsed <= 0) return;

        const elapsed_u64: u64 = @intCast(elapsed);
        const window_u64: u64 = @intCast(self.window_ns);
        const tokens = elapsed_u64 * self.max_requests / window_u64;
        if (tokens == 0) return;

        bucket.tokens = @min(self.max_requests, bucket.tokens + tokens);
        if (bucket.tokens == self.max_requests) {
            bucket.last_refill_ns = now;
        } else {
            const consumed_ns = @divTrunc(
                @as(i96, @intCast(tokens)) * self.window_ns,
                @as(i96, @intCast(self.max_requests)),
            );
            bucket.last_refill_ns += consumed_ns;
        }
    }

    fn retryAfter(self: *RateLimit, bucket: *const Bucket, now: i96) u64 {
        const per_token_ns = @divTrunc(
            self.window_ns,
            @as(i96, @intCast(self.max_requests)),
        );
        const elapsed = now - bucket.last_refill_ns;
        var remaining = per_token_ns - elapsed;
        if (remaining < 0) remaining = 0;
        const seconds = @divTrunc(
            remaining + std.time.ns_per_s - 1,
            std.time.ns_per_s,
        );
        return @max(@as(u64, 1), @as(u64, @intCast(seconds)));
    }
};

test "rate limit allows then rejects the same client" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var limiter = try RateLimit.init(allocator, .{
        .max_requests = 1,
        .window = .fromSeconds(1),
        .max_clients = 4,
    });
    defer limiter.deinit();

    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var first = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .client_info = .{
            .address = .{ .ip4 = .loopback(1234) },
        },
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{limiter.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };
    try first.run();
    try std.testing.expectEqual(@as(u16, 200), first.response.status);

    var second = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .client_info = .{
            .address = .{ .ip4 = .loopback(1234) },
        },
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{limiter.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };
    try second.run();
    try std.testing.expectEqual(@as(u16, 429), second.response.status);
    try std.testing.expect(second.response.header("retry-after") != null);

    var other = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .client_info = .{
            .address = .{ .ip4 = .loopback(5678) },
        },
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{limiter.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };
    try other.run();
    try std.testing.expectEqual(@as(u16, 200), other.response.status);
}
