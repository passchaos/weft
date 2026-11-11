const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const response_mod = @import("../response.zig");

const Header = netz.http1.Header;

/// Bounded in-memory cache for safe GET responses.
///
/// The cache skips authenticated requests, responses that set cookies, and
/// responses carrying `Vary`. Unsafe methods clear the whole cache. This is a
/// conservative shared-nothing cache; multi-process deployments should use an
/// external cache.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    max_entries: usize,
    max_bytes: usize,
    default_ttl_ns: i96,
    bytes: usize = 0,
    tick: u64 = 0,

    pub const Options = struct {
        max_entries: usize = 1024,
        max_bytes: usize = 8 * 1024 * 1024,
        /// Used when the response has no `Cache-Control: max-age`.
        default_ttl: std.Io.Duration = .fromSeconds(30),
    };

    const Entry = struct {
        status: u16,
        headers: []Header,
        body: []u8,
        expires_ns: i96,
        last_used: u64,
        size: usize,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Cache {
        if (options.max_entries == 0 or
            options.max_bytes == 0 or
            options.default_ttl.nanoseconds <= 0)
        {
            return error.InvalidOptions;
        }
        return .{
            .allocator = allocator,
            .max_entries = options.max_entries,
            .max_bytes = options.max_bytes,
            .default_ttl_ns = options.default_ttl.nanoseconds,
        };
    }

    pub fn deinit(self: *Cache) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |item| {
            self.freeEntry(item.value_ptr.*);
            self.allocator.free(item.key_ptr.*);
            self.allocator.destroy(item.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn handler(self: *Cache) handler_mod.Handler {
        return handler_mod.withContext(Cache, self, call);
    }

    fn call(self: *Cache, ctx: *ctx_mod.Ctx) anyerror!void {
        if (isSafe(ctx.method())) {
            if (try self.serve(ctx)) return;
        } else {
            self.clear(ctx.io);
            return ctx.next();
        }
        ctx.next() catch |err| {
            self.store(ctx) catch {};
            return err;
        };
        try self.store(ctx);
    }

    fn serve(self: *Cache, ctx: *ctx_mod.Ctx) !bool {
        if (ctx.method() != .GET) return false;
        if (ctx.header("authorization") != null or
            ctx.header("cookie") != null)
        {
            return false;
        }
        const now = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
        const key = try cacheKey(ctx.arena, ctx);
        self.mutex.lock(ctx.io) catch return false;
        defer self.mutex.unlock(ctx.io);
        const entry = self.entries.get(key) orelse return false;
        if (now >= entry.expires_ns) {
            if (self.entries.fetchRemove(key)) |removed| {
                self.removeEntry(removed.value);
                self.allocator.free(removed.key);
            }
            return false;
        }
        entry.last_used = self.tick;
        self.tick += 1;

        ctx.setStatus(entry.status);
        for (entry.headers) |header| {
            try ctx.setHeader(header.name, header.value);
        }
        try ctx.response.setBody(try ctx.arena.dupe(u8, entry.body));
        return true;
    }

    fn store(self: *Cache, ctx: *ctx_mod.Ctx) !void {
        if (ctx.method() != .GET) return;
        if (ctx.header("authorization") != null or
            ctx.header("cookie") != null)
        {
            return;
        }
        if (ctx.response.status != 200 or
            ctx.response.stream != null or
            ctx.response.upgrade != null)
        {
            return;
        }
        if (ctx.response.header("set-cookie") != null or
            ctx.response.header("vary") != null)
        {
            return;
        }
        const ttl = cacheTtl(ctx.response.header("cache-control")) orelse
            self.default_ttl_ns;
        if (ttl <= 0) return;
        const now = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
        const key = try cacheKey(ctx.arena, ctx);

        var header_count: usize = 0;
        for (ctx.response.headers.items) |header| {
            if (cacheableHeader(header.name)) header_count += 1;
        }
        const headers = try self.allocator.alloc(Header, header_count);
        errdefer self.allocator.free(headers);
        var copied_headers: usize = 0;
        errdefer {
            for (headers[0..copied_headers]) |header| {
                self.allocator.free(header.name);
                self.allocator.free(header.value);
            }
        }
        var size = ctx.response.body.len;
        for (ctx.response.headers.items) |header| {
            if (!cacheableHeader(header.name)) continue;
            const name = try self.allocator.dupe(u8, header.name);
            errdefer self.allocator.free(name);
            const value = try self.allocator.dupe(u8, header.value);
            errdefer self.allocator.free(value);
            headers[copied_headers] = .{ .name = name, .value = value };
            copied_headers += 1;
            size = std.math.add(usize, size, name.len + value.len) catch
                return error.ResponseTooLarge;
        }
        if (size > self.max_bytes) return error.ResponseTooLarge;
        const body = try self.allocator.dupe(u8, ctx.response.body);
        errdefer self.allocator.free(body);

        self.mutex.lock(ctx.io) catch return;
        defer self.mutex.unlock(ctx.io);
        if (self.entries.fetchRemove(key)) |removed| {
            self.removeEntry(removed.value);
            self.allocator.free(removed.key);
        }
        while (self.entries.count() >= self.max_entries or
            self.bytes + size > self.max_bytes)
        {
            if (!self.evictOldest()) break;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .status = ctx.response.status,
            .headers = headers,
            .body = body,
            .expires_ns = now + ttl,
            .last_used = self.tick,
            .size = size,
        };
        self.tick += 1;
        try self.entries.put(self.allocator, owned_key, entry);
        self.bytes += size;
    }

    fn clear(self: *Cache, io: std.Io) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        var iterator = self.entries.iterator();
        while (iterator.next()) |item| {
            self.freeEntry(item.value_ptr.*);
            self.allocator.free(item.key_ptr.*);
            self.allocator.destroy(item.value_ptr.*);
        }
        self.entries.clearRetainingCapacity();
        self.bytes = 0;
    }

    fn evictOldest(self: *Cache) bool {
        var oldest_key: ?[]const u8 = null;
        var oldest_tick: u64 = std.math.maxInt(u64);
        var iterator = self.entries.iterator();
        while (iterator.next()) |item| {
            if (item.value_ptr.*.last_used < oldest_tick) {
                oldest_tick = item.value_ptr.*.last_used;
                oldest_key = item.key_ptr.*;
            }
        }
        const key = oldest_key orelse return false;
        const entry = self.entries.get(key) orelse return false;
        _ = self.entries.remove(key);
        self.freeEntry(entry);
        self.allocator.free(key);
        self.allocator.destroy(entry);
        return true;
    }

    fn removeEntry(self: *Cache, entry: *Entry) void {
        self.bytes -= entry.size;
        self.freeEntry(entry);
        self.allocator.destroy(entry);
    }

    fn freeEntry(self: *Cache, entry: *Entry) void {
        for (entry.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(entry.headers);
        self.allocator.free(entry.body);
        entry.* = undefined;
    }
};

fn isSafe(method: netz.http1.Method) bool {
    return switch (method) {
        .GET, .HEAD, .OPTIONS, .TRACE => true,
        else => false,
    };
}

fn cacheKey(allocator: std.mem.Allocator, ctx: *ctx_mod.Ctx) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\x00{s}\x00{s}",
        .{
            ctx.method().string(),
            ctx.header("host") orelse "",
            ctx.target(),
        },
    );
}

fn cacheTtl(value: ?[]const u8) ?i96 {
    const raw = value orelse return null;
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        const directive = std.mem.trim(u8, part, " \t");
        if (std.ascii.startsWithIgnoreCase(directive, "no-store") or
            std.ascii.startsWithIgnoreCase(directive, "private") or
            std.ascii.startsWithIgnoreCase(directive, "no-cache"))
        {
            return 0;
        }
        if (std.ascii.startsWithIgnoreCase(directive, "max-age=")) {
            const seconds = std.fmt.parseInt(
                i64,
                std.mem.trim(
                    u8,
                    directive["max-age=".len..],
                    " \t",
                ),
                10,
            ) catch return 0;
            if (seconds <= 0) return 0;
            return std.math.mul(i96, seconds, std.time.ns_per_s) catch
                std.math.maxInt(i96);
        }
    }
    return null;
}

fn cacheableHeader(name: []const u8) bool {
    return !std.ascii.eqlIgnoreCase(name, "set-cookie") and
        !std.ascii.eqlIgnoreCase(name, "date") and
        !std.ascii.eqlIgnoreCase(name, "connection") and
        !std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    request: netz.http1.Request,
    ctx: ctx_mod.Ctx,

    fn init(
        self: *TestContext,
        allocator: std.mem.Allocator,
        method: netz.http1.Method,
        target: []const u8,
        headers: []const Header,
        middleware: []const handler_mod.Handler,
        final_handler: handler_mod.Handler,
    ) !void {
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.request = .{
            .method = method,
            .target = target,
            .version = .http_1_1,
            .headers = @constCast(headers),
            .body = "",
            .consumed = 0,
        };
        self.ctx = .{
            .app = undefined,
            .io = std.testing.io,
            .arena = self.arena.allocator(),
            .limits = .{},
            .request = &self.request,
            .response = response_mod.Response.init(
                self.arena.allocator(),
                4096,
            ),
            .middleware = middleware,
            .final_handler = final_handler,
        };
    }

    fn deinit(self: *TestContext) void {
        self.arena.deinit();
    }
};

test "cache serves repeat GETs and clears on unsafe methods" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, .{
        .max_entries = 4,
        .max_bytes = 4096,
        .default_ttl = .fromSeconds(60),
    });
    defer cache.deinit();

    const State = struct {
        calls: usize = 0,
    };
    var state = State{};
    const Run = struct {
        fn run(raw: ?*anyopaque, ctx: *ctx_mod.Ctx) anyerror!void {
            const state_ptr: *State = @ptrCast(@alignCast(raw.?));
            state_ptr.calls += 1;
            try ctx.text(try std.fmt.allocPrint(
                ctx.arena,
                "call-{d}",
                .{state_ptr.calls},
            ));
        }
    };
    const handler = handler_mod.Handler{
        .context = &state,
        .call_fn = Run.run,
    };
    const middleware = cache.handler();

    var first: TestContext = undefined;
    try first.init(
        allocator,
        .GET,
        "/cached",
        &.{},
        &.{middleware},
        handler,
    );
    defer first.deinit();
    try first.ctx.run();
    try std.testing.expectEqualStrings("call-1", first.ctx.response.body);

    var second: TestContext = undefined;
    try second.init(
        allocator,
        .GET,
        "/cached",
        &.{},
        &.{middleware},
        handler,
    );
    defer second.deinit();
    try second.ctx.run();
    try std.testing.expectEqualStrings("call-1", second.ctx.response.body);
    try std.testing.expectEqual(@as(usize, 1), state.calls);

    var post: TestContext = undefined;
    try post.init(
        allocator,
        .POST,
        "/cached",
        &.{},
        &.{middleware},
        handler,
    );
    defer post.deinit();
    try post.ctx.run();
    try std.testing.expectEqual(@as(usize, 2), state.calls);

    var third: TestContext = undefined;
    try third.init(
        allocator,
        .GET,
        "/cached",
        &.{},
        &.{middleware},
        handler,
    );
    defer third.deinit();
    try third.ctx.run();
    try std.testing.expectEqualStrings("call-3", third.ctx.response.body);

    var auth_headers = [_]Header{.{
        .name = "authorization",
        .value = "Bearer token",
    }};
    var authenticated: TestContext = undefined;
    try authenticated.init(
        allocator,
        .GET,
        "/cached",
        &auth_headers,
        &.{middleware},
        handler,
    );
    defer authenticated.deinit();
    try authenticated.ctx.run();
    try std.testing.expectEqual(@as(usize, 4), state.calls);
}
