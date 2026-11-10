const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// Transport/version metadata for the current request.
pub const Protocol = enum {
    http_1_1,
    http_2,
    http_3,
};

pub const ClientInfo = struct {
    /// Peer address when the adapter can expose one.
    address: ?std.Io.net.IpAddress = null,
    protocol: Protocol = .http_1_1,
    tls: bool = false,
    /// Verified client certificate chain for mutual TLS, leaf first. Empty
    /// when the listener does not request client certificates.
    peer_certificates: []const []const u8 = &.{},
};

/// Resolve the client address, optionally honoring the leftmost
/// `X-Forwarded-For` entry. The header is only consulted when the caller
/// explicitly trusts its proxy. `peer` may be null for transports without an
/// IP peer (for example a Unix socket); a trusted header still supplies an
/// address in that case.
pub fn resolveClientAddress(
    headers: anytype,
    peer: ?std.Io.net.IpAddress,
    trust_forwarded_for: bool,
) ?std.Io.net.IpAddress {
    if (!trust_forwarded_for) return peer;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for")) continue;
        var entries = std.mem.splitScalar(u8, header.value, ',');
        while (entries.next()) |raw| {
            var candidate = std.mem.trim(u8, raw, " \t");
            if (candidate.len >= 2 and candidate[0] == '"' and
                candidate[candidate.len - 1] == '"')
            {
                candidate = candidate[1 .. candidate.len - 1];
            }
            if (candidate.len == 0) continue;
            const parsed = std.Io.net.IpAddress.parse(candidate, 0) catch
                continue;
            return parsed;
        }
        return peer;
    }
    return peer;
}

/// Maximum path parameters captured for one route. The bound keeps the matcher
/// allocation-free until a route actually matches.
pub const max_params = 16;

/// The single handler contract used by routes and middleware.
///
/// A handler receives only `*Ctx`. Application state is available through
/// `ctx.app`; parameterized middleware can store its state in `context` and use
/// `withContext`.
pub const Handler = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, *ctx_mod.Ctx) anyerror!void,

    pub fn call(self: Handler, ctx: *ctx_mod.Ctx) anyerror!void {
        return self.call_fn(self.context, ctx);
    }
};

/// Maximum distinct request-local values. The bound keeps `Locals` inline
/// instead of allocating a hash map for the usual one or two entries.
pub const max_locals = 16;

/// Request-scoped typed locals.
///
/// Keys are `@typeName(T)` strings, so only one value per type is stored.
/// Values are allocated in the request arena and are valid until the response
/// has been written.
pub const Locals = struct {
    const Entry = struct {
        key: []const u8,
        value: *anyopaque,
    };

    entries: [max_locals]Entry = undefined,
    len: usize = 0,

    pub fn put(
        self: *Locals,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: *anyopaque,
    ) !void {
        _ = allocator;
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.value = value;
                return;
            }
        }
        if (self.len >= self.entries.len) return error.TooManyLocals;
        self.entries[self.len] = .{ .key = key, .value = value };
        self.len += 1;
    }

    pub fn get(self: *const Locals, key: []const u8) ?*anyopaque {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

/// Wrap a compile-time route handler that receives the application context.
pub fn handlerFor(
    comptime H: type,
    comptime f: fn (*H, *ctx_mod.Ctx) anyerror!void,
) Handler {
    return .{
        .context = null,
        .call_fn = struct {
            fn call(_: ?*anyopaque, ctx: *ctx_mod.Ctx) anyerror!void {
                const app: *H = @ptrCast(@alignCast(ctx.app));
                return f(app, ctx);
            }
        }.call,
    };
}

/// Wrap a plain middleware/handler function.
pub fn handler(comptime f: fn (*ctx_mod.Ctx) anyerror!void) Handler {
    return .{
        .context = null,
        .call_fn = struct {
            fn call(_: ?*anyopaque, ctx: *ctx_mod.Ctx) anyerror!void {
                return f(ctx);
            }
        }.call,
    };
}

/// Wrap a parameterized middleware/handler. `context` must outlive the router.
pub fn withContext(
    comptime T: type,
    context: *T,
    comptime f: fn (*T, *ctx_mod.Ctx) anyerror!void,
) Handler {
    return .{
        .context = context,
        .call_fn = struct {
            fn call(raw: ?*anyopaque, ctx: *ctx_mod.Ctx) anyerror!void {
                const typed: *T = @ptrCast(@alignCast(raw.?));
                return f(typed, ctx);
            }
        }.call,
    };
}

test "client address honors a trusted forwarded-for header" {
    const peer = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    var headers = [_]netz.http1.Header{.{
        .name = "X-Forwarded-For",
        .value = "203.0.113.7, 10.0.0.1",
    }};

    const trusted = resolveClientAddress(&headers, peer, true).?;
    const expected = try std.Io.net.IpAddress.parse("203.0.113.7", 0);
    try std.testing.expect(trusted.eql(&expected));

    const untrusted = resolveClientAddress(&headers, peer, false).?;
    try std.testing.expect(untrusted.eql(&peer));

    var invalid = [_]netz.http1.Header{.{
        .name = "X-Forwarded-For",
        .value = "not-an-ip",
    }};
    const fallback = resolveClientAddress(&invalid, peer, true).?;
    try std.testing.expect(fallback.eql(&peer));

    var quoted = [_]netz.http1.Header{.{
        .name = "X-Forwarded-For",
        .value = "\"2001:db8::1\"",
    }};
    const ipv6 = resolveClientAddress(&quoted, peer, true).?;
    const expected6 = try std.Io.net.IpAddress.parse("2001:db8::1", 0);
    try std.testing.expect(ipv6.eql(&expected6));

    // A Unix-socket peer has no IP address, but a trusted proxy header can
    // still supply one.
    const forwarded_without_peer =
        resolveClientAddress(&headers, null, true).?;
    try std.testing.expect(forwarded_without_peer.eql(&expected));
    try std.testing.expect(resolveClientAddress(&headers, null, false) == null);
}

test "typed locals round-trip through the request arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var locals = Locals{};
    const value = @as(u32, 42);
    const ptr = try arena.allocator().create(u32);
    ptr.* = value;
    try locals.put(arena.allocator(), @typeName(u32), @ptrCast(ptr));
    const raw = locals.get(@typeName(u32)).?;
    const typed: *u32 = @ptrCast(@alignCast(raw));
    try std.testing.expectEqual(@as(u32, 42), typed.*);
}

test "locals replace values and stay bounded" {
    var locals = Locals{};
    var first: u32 = 1;
    var second: u32 = 2;
    try locals.put(undefined, "key", @ptrCast(&first));
    try locals.put(undefined, "key", @ptrCast(&second));
    try std.testing.expect(
        locals.get("key").? == @as(*anyopaque, @ptrCast(&second)),
    );

    locals = .{};
    const keys = comptime blk: {
        var result: [max_locals + 1][]const u8 = undefined;
        for (&result, 0..) |*slot, index| {
            slot.* = std.fmt.comptimePrint("key{d}", .{index});
        }
        break :blk result;
    };
    for (keys[0..max_locals]) |key| {
        try locals.put(undefined, key, @ptrCast(&first));
    }
    try std.testing.expectError(
        error.TooManyLocals,
        locals.put(undefined, keys[max_locals], @ptrCast(&first)),
    );
}
