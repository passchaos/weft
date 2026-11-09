const std = @import("std");
const ctx_mod = @import("../ctx.zig");

/// Bounded per-client token bucket rate limiter.
///
/// Clients are keyed by the peer IP address without the ephemeral source port,
/// so reconnecting does not create a fresh bucket. IPv4-mapped IPv6 addresses
/// share the IPv4 key. When an adapter cannot provide an address, all such
/// requests share one bucket. Bucket storage is fixed at construction, a
/// bounded hash index makes client lookup independent of the table size, and
/// the least-recently-seen client is evicted when the table is full.
///
/// Rate limiting uses the direct peer address. Applications behind a reverse
/// proxy must apply their own trusted-proxy policy before enabling this.
pub const RateLimit = struct {
    allocator: std.mem.Allocator,
    max_requests: u64,
    window_ns: i96,
    buckets: []Bucket,
    /// Maps a client key to its bucket slot. Capacity is reserved in `init`,
    /// so insertion after an eviction never allocates.
    index: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    mutex: std.Io.Mutex = .init,
    global_bucket: Bucket = .{},
    key_header: ?[]const u8 = null,
    /// Number of never-used bucket slots. Slots at or above this index have
    /// never held a client; reused slots stay on the LRU list instead.
    free_next: usize = 0,
    /// Least-recently-used bucket head (eviction victim) and most-recently-used
    /// tail.
    lru_head: u32 = invalid_slot,
    lru_tail: u32 = invalid_slot,

    pub const Options = struct {
        max_requests: usize = 100,
        window: std.Io.Duration = .fromSeconds(1),
        max_clients: usize = 4096,
        /// Optional request header whose value identifies the client, such as
        /// an API key. When the header is absent the peer address is used.
        /// Values are hashed, so secrets are not stored in the bucket table.
        key_header: ?[]const u8 = null,
    };

    /// Client identity without the ephemeral port, or a hashed application
    /// key when `Options.key_header` is configured.
    const Key = union(enum) {
        ip4: [4]u8,
        ip6: [16]u8,
        application: u64,
    };

    const Bucket = struct {
        key: ?Key = null,
        used: bool = false,
        tokens: u64 = 0,
        last_refill_ns: i96 = 0,
        /// Intrusive least-recently-used list links. `invalid_slot` terminates
        /// the list.
        prev: u32 = invalid_slot,
        next: u32 = invalid_slot,
    };

    const invalid_slot = std.math.maxInt(u32);

    pub fn init(
        allocator: std.mem.Allocator,
        options: Options,
    ) !RateLimit {
        if (options.max_requests == 0 or
            options.window.nanoseconds <= 0 or
            options.max_clients == 0 or
            options.max_clients > std.math.maxInt(u32))
        {
            return error.InvalidOptions;
        }

        const buckets = try allocator.alloc(Bucket, options.max_clients);
        for (buckets) |*bucket| bucket.* = .{};
        errdefer allocator.free(buckets);

        var index: std.AutoHashMapUnmanaged(Key, usize) = .empty;
        errdefer index.deinit(allocator);
        try index.ensureTotalCapacity(
            allocator,
            @intCast(options.max_clients),
        );

        return .{
            .allocator = allocator,
            .max_requests = options.max_requests,
            .window_ns = options.window.nanoseconds,
            .buckets = buckets,
            .index = index,
            .key_header = options.key_header,
        };
    }

    pub fn deinit(self: *RateLimit) void {
        self.index.deinit(self.allocator);
        self.allocator.free(self.buckets);
        self.* = undefined;
    }

    pub fn handler(self: *RateLimit) ctx_mod.Handler {
        return ctx_mod.withContext(RateLimit, self, call);
    }

    fn call(self: *RateLimit, ctx: *ctx_mod.Ctx) anyerror!void {
        const address = ctx.clientAddress();
        const now = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds;
        const override_key: ?Key = if (self.key_header) |name|
            if (ctx.header(name)) |value|
                .{ .application = std.hash.Wyhash.hash(0, value) }
            else
                null
        else
            null;

        var limited = false;
        var retry_after: u64 = 1;
        try self.mutex.lock(ctx.io);
        {
            defer self.mutex.unlock(ctx.io);

            const bucket = try self.bucketFor(address, override_key, now);
            self.refill(bucket, now);
            if (bucket.tokens == 0) {
                limited = true;
                retry_after = self.retryAfter(bucket, now);
            } else {
                bucket.tokens -= 1;
            }
        }

        if (limited) {
            // Rejections are the busiest path under a flood; format the field
            // on the stack instead of allocating per response.
            var retry_buffer: [24]u8 = undefined;
            const retry_value = std.fmt.bufPrint(
                &retry_buffer,
                "{d}",
                .{retry_after},
            ) catch "1";
            ctx.setStatus(429);
            try ctx.setHeader("Retry-After", retry_value);
            try ctx.text("Too Many Requests");
            return;
        }

        try ctx.next();
    }

    fn bucketFor(
        self: *RateLimit,
        address: ?std.Io.net.IpAddress,
        override_key: ?Key,
        now: i96,
    ) !*Bucket {
        const key = override_key orelse
            if (address) |value| keyFor(value) else null;
        if (key == null) {
            if (!self.global_bucket.used) {
                self.global_bucket = .{
                    .used = true,
                    .tokens = self.max_requests,
                    .last_refill_ns = now,
                };
            }
            return &self.global_bucket;
        }

        if (self.index.get(key.?)) |slot| {
            self.touch(slot);
            return &self.buckets[slot];
        }

        // Prefer a never-used slot; once the table is full, evict the
        // least-recently-used bucket in O(1) through the intrusive list.
        var slot: usize = undefined;
        if (self.free_next < self.buckets.len) {
            slot = self.free_next;
            self.free_next += 1;
        } else {
            const victim = self.lru_head;
            std.debug.assert(victim != invalid_slot);
            slot = victim;
            self.unlink(victim);
            if (self.buckets[slot].key) |old_key| _ = self.index.remove(old_key);
        }
        const victim = &self.buckets[slot];
        victim.* = .{
            .key = key,
            .used = true,
            .tokens = self.max_requests,
            .last_refill_ns = now,
        };
        self.appendTail(@intCast(slot));
        // Capacity for `max_clients` entries is reserved in `init` and an
        // eviction removes one entry first, so this insert cannot grow the
        // table. Keep the bucket usable if an allocator failure still occurs.
        self.index.put(self.allocator, key.?, slot) catch {};
        return victim;
    }

    /// Move a used bucket to the most-recently-used end of the list.
    fn touch(self: *RateLimit, slot: usize) void {
        const index: u32 = @intCast(slot);
        if (self.lru_tail == index) return;
        self.unlink(index);
        self.appendTail(index);
    }

    fn unlink(self: *RateLimit, index: u32) void {
        const bucket = &self.buckets[index];
        const prev = bucket.prev;
        const next = bucket.next;
        if (prev != invalid_slot) {
            self.buckets[prev].next = next;
        } else {
            self.lru_head = next;
        }
        if (next != invalid_slot) {
            self.buckets[next].prev = prev;
        } else {
            self.lru_tail = prev;
        }
        bucket.prev = invalid_slot;
        bucket.next = invalid_slot;
    }

    fn appendTail(self: *RateLimit, index: u32) void {
        const bucket = &self.buckets[index];
        bucket.prev = self.lru_tail;
        bucket.next = invalid_slot;
        if (self.lru_tail != invalid_slot) {
            self.buckets[self.lru_tail].next = index;
        } else {
            self.lru_head = index;
        }
        self.lru_tail = index;
    }

    fn keyFor(address: std.Io.net.IpAddress) Key {
        return switch (address) {
            .ip4 => |value| .{ .ip4 = value.bytes },
            .ip6 => |value| if (std.Io.net.Ip4Address.fromIp6(value)) |mapped|
                .{ .ip4 = mapped.bytes }
            else
                .{ .ip6 = value.bytes },
        };
    }

    fn refill(self: *RateLimit, bucket: *Bucket, now: i96) void {
        const elapsed = now - bucket.last_refill_ns;
        if (elapsed <= 0) return;

        const elapsed_u64: u64 = @intCast(@min(
            elapsed,
            @as(i96, std.math.maxInt(u64)),
        ));
        const window_u64: u64 = @intCast(self.window_ns);
        const scaled = @as(u128, elapsed_u64) *
            @as(u128, self.max_requests) / @as(u128, window_u64);
        const tokens: u64 = @intCast(@min(
            scaled,
            @as(u128, self.max_requests),
        ));
        if (tokens == 0) return;

        bucket.tokens = @min(self.max_requests, bucket.tokens +| tokens);
        if (bucket.tokens == self.max_requests) {
            bucket.last_refill_ns = now;
        } else {
            const consumed_ns: i96 = @intCast(
                @as(u128, tokens) *
                    @as(u128, @intCast(self.window_ns)) /
                    @as(u128, self.max_requests),
            );
            bucket.last_refill_ns +|= consumed_ns;
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
            .address = .{ .ip4 = .{
                .bytes = .{ 127, 0, 0, 2 },
                .port = 5678,
            } },
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

    // A reconnect from the same IP with a new source port shares the bucket.
    var reconnected = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .client_info = .{
            .address = .{ .ip4 = .loopback(4321) },
        },
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{limiter.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };
    try reconnected.run();
    try std.testing.expectEqual(@as(u16, 429), reconnected.response.status);
}

test "rate limit can key on an application header" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var limiter = try RateLimit.init(allocator, .{
        .max_requests = 1,
        .window = .fromSeconds(1),
        .max_clients = 4,
        .key_header = "x-api-key",
    });
    defer limiter.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "X-Api-Key",
        .value = "alpha",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };

    const run = struct {
        fn once(
            limiter_: *RateLimit,
            arena_: std.mem.Allocator,
            request_: *@import("netz").http1.Request,
        ) !u16 {
            var context = ctx_mod.Ctx{
                .app = undefined,
                .io = std.testing.io,
                .arena = arena_,
                .limits = .{},
                .request = request_,
                .client_info = .{
                    .address = .{ .ip4 = .loopback(1234) },
                },
                .response = ctx_mod.Response.init(arena_, 1024),
                .middleware = &.{limiter_.handler()},
                .final_handler = ctx_mod.handler(struct {
                    fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                        try ctx.text("ok");
                    }
                }.handle),
            };
            try context.run();
            return context.response.status;
        }
    };

    try std.testing.expectEqual(
        @as(u16, 200),
        try run.once(&limiter, arena.allocator(), &request),
    );
    // Same key, same address: limited.
    try std.testing.expectEqual(
        @as(u16, 429),
        try run.once(&limiter, arena.allocator(), &request),
    );

    // A different key from the same address gets its own bucket.
    var other_headers = [_]@import("netz").http1.Header{.{
        .name = "X-Api-Key",
        .value = "beta",
    }};
    var other_request = request;
    other_request.headers = &other_headers;
    try std.testing.expectEqual(
        @as(u16, 200),
        try run.once(&limiter, arena.allocator(), &other_request),
    );
}

test "rate limit index tracks evicted buckets" {
    const allocator = std.testing.allocator;
    var limiter = try RateLimit.init(allocator, .{
        .max_requests = 1,
        .window = .fromSeconds(1),
        .max_clients = 2,
    });
    defer limiter.deinit();

    const run = struct {
        fn once(
            limiter_: *RateLimit,
            address: std.Io.net.IpAddress,
        ) !u16 {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var request: @import("netz").http1.Request = .{
                .method = .GET,
                .target = "/",
                .version = .http_1_1,
                .headers = &.{},
                .body = "",
                .consumed = 0,
            };
            var context = ctx_mod.Ctx{
                .app = undefined,
                .io = std.testing.io,
                .arena = arena.allocator(),
                .limits = .{},
                .request = &request,
                .client_info = .{ .address = address },
                .response = ctx_mod.Response.init(arena.allocator(), 1024),
                .middleware = &.{limiter_.handler()},
                .final_handler = ctx_mod.handler(struct {
                    fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                        try ctx.text("ok");
                    }
                }.handle),
            };
            try context.run();
            return context.response.status;
        }
    };

    const first = try std.Io.net.IpAddress.parse("127.0.0.1", 1000);
    const second = try std.Io.net.IpAddress.parse("127.0.0.2", 1000);
    const third = try std.Io.net.IpAddress.parse("127.0.0.3", 1000);

    try std.testing.expectEqual(@as(u16, 200), try run.once(&limiter, first));
    try std.testing.expectEqual(@as(u16, 429), try run.once(&limiter, first));
    try std.testing.expectEqual(@as(u16, 200), try run.once(&limiter, second));

    // The third client evicts the least-recently-seen bucket, and the index
    // must forget the evicted key instead of pointing at its reused slot.
    try std.testing.expectEqual(@as(u16, 200), try run.once(&limiter, third));
    try std.testing.expectEqual(@as(u16, 200), try run.once(&limiter, first));
    try std.testing.expectEqual(@as(u16, 429), try run.once(&limiter, first));
    try std.testing.expectEqual(@as(u16, 429), try run.once(&limiter, third));
}

test "rate limit eviction follows most-recent use" {
    const allocator = std.testing.allocator;
    var limiter = try RateLimit.init(allocator, .{
        .max_requests = 1,
        .window = .fromSeconds(1),
        .max_clients = 2,
    });
    defer limiter.deinit();

    const run = struct {
        fn once(
            limiter_: *RateLimit,
            address: std.Io.net.IpAddress,
        ) !u16 {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var request: @import("netz").http1.Request = .{
                .method = .GET,
                .target = "/",
                .version = .http_1_1,
                .headers = &.{},
                .body = "",
                .consumed = 0,
            };
            var context = ctx_mod.Ctx{
                .app = undefined,
                .io = std.testing.io,
                .arena = arena.allocator(),
                .limits = .{},
                .request = &request,
                .client_info = .{ .address = address },
                .response = ctx_mod.Response.init(arena.allocator(), 1024),
                .middleware = &.{limiter_.handler()},
                .final_handler = ctx_mod.handler(struct {
                    fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                        try ctx.text("ok");
                    }
                }.handle),
            };
            try context.run();
            return context.response.status;
        }
    };

    const first = try std.Io.net.IpAddress.parse("127.0.0.1", 1000);
    const second = try std.Io.net.IpAddress.parse("127.0.0.2", 1000);
    const third = try std.Io.net.IpAddress.parse("127.0.0.3", 1000);

    try std.testing.expectEqual(@as(u16, 200), try run.once(&limiter, first));
    try std.testing.expectEqual(@as(u16, 200), try run.once(&limiter, second));
    // Re-using `first` makes it the most recent, so `third` evicts `second`.
    try std.testing.expectEqual(@as(u16, 429), try run.once(&limiter, first));
    try std.testing.expectEqual(@as(u16, 200), try run.once(&limiter, third));
    try std.testing.expectEqual(@as(u16, 200), try run.once(&limiter, second));
    try std.testing.expectEqual(@as(u16, 429), try run.once(&limiter, third));
}
