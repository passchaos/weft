const std = @import("std");
const netz = @import("netz");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");

pub const Response = response_mod.Response;
pub const Limits = limits_mod.Limits;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

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
    call_fn: *const fn (?*anyopaque, *Ctx) anyerror!void,

    pub fn call(self: Handler, ctx: *Ctx) anyerror!void {
        return self.call_fn(self.context, ctx);
    }
};

/// Request-scoped typed locals.
///
/// Keys are `@typeName(T)` strings, so only one value per type is stored.
/// Values are allocated in the request arena and are valid until the response
/// has been written.
pub const Locals = struct {
    map: std.StringHashMapUnmanaged(*anyopaque) = .empty,

    pub fn put(
        self: *Locals,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: *anyopaque,
    ) !void {
        try self.map.put(allocator, key, value);
    }

    pub fn get(self: *const Locals, key: []const u8) ?*anyopaque {
        return self.map.get(key);
    }
};

/// Per-request execution context.
///
/// The chain is explicit: `middleware` runs first, then `final_handler`.
/// Middleware calls `ctx.next()` to continue; not calling it short-circuits.
/// `next()` may be called at most once per handler invocation.
pub const Ctx = struct {
    app: *anyopaque,
    io: std.Io,
    arena: std.mem.Allocator,
    limits: Limits,
    request: *const netz.http1.Request,
    query: []const u8 = "",
    params: []const Param = &.{},
    response: Response,
    locals: Locals = .{},
    middleware: []const Handler = &.{},
    final_handler: Handler,
    index: usize = 0,
    final_called: bool = false,
    next_allowed: bool = false,

    pub fn run(self: *Ctx) anyerror!void {
        self.index = 0;
        self.final_called = false;
        self.next_allowed = true;
        try self.next();
    }

    pub fn next(self: *Ctx) anyerror!void {
        if (!self.next_allowed) return error.NextNotAllowed;
        self.next_allowed = false;

        if (self.index < self.middleware.len) {
            const middleware_handler = self.middleware[self.index];
            self.index += 1;
            return self.callHandler(middleware_handler);
        }

        if (!self.final_called) {
            self.final_called = true;
            return self.callHandler(self.final_handler);
        }
    }

    fn callHandler(self: *Ctx, entry: Handler) anyerror!void {
        const previous = self.next_allowed;
        self.next_allowed = true;
        defer self.next_allowed = previous;
        return entry.call(self);
    }

    pub fn method(self: *const Ctx) netz.http1.Method {
        return self.request.method;
    }

    pub fn target(self: *const Ctx) []const u8 {
        return self.request.target;
    }

    pub fn header(self: *const Ctx, name: []const u8) ?[]const u8 {
        return self.request.header(name);
    }

    pub fn body(self: *const Ctx) []const u8 {
        return self.request.body;
    }

    pub fn param(self: *const Ctx, name: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    /// Look up the first raw query value. Percent-decoding is intentionally
    /// left to the application for now.
    pub fn queryParam(self: *const Ctx, name: []const u8) ?[]const u8 {
        var pairs = std.mem.splitScalar(u8, self.query, '&');
        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse
                continue;
            if (std.mem.eql(u8, pair[0..equals], name)) {
                return pair[equals + 1 ..];
            }
        }
        return null;
    }

    pub fn set(self: *Ctx, comptime T: type, value: T) !void {
        const ptr = try self.arena.create(T);
        ptr.* = value;
        try self.locals.put(
            self.arena,
            @typeName(T),
            @ptrCast(ptr),
        );
    }

    pub fn get(self: *Ctx, comptime T: type) ?T {
        const raw = self.locals.get(@typeName(T)) orelse return null;
        const ptr: *T = @ptrCast(@alignCast(raw));
        return ptr.*;
    }

    pub fn setStatus(self: *Ctx, status: u16) void {
        self.response.setStatus(status);
    }

    pub fn setHeader(
        self: *Ctx,
        name: []const u8,
        value: []const u8,
    ) !void {
        try self.response.setHeader(name, value);
    }

    pub fn text(self: *Ctx, value: []const u8) !void {
        try self.response.text(value);
    }

    pub fn json(self: *Ctx, value: anytype) !void {
        try self.response.json(value);
    }

    pub fn notFound(self: *Ctx) !void {
        self.setStatus(404);
        try self.text("Not Found");
    }

    pub fn internalError(self: *Ctx) !void {
        self.setStatus(500);
        try self.text("Internal Server Error");
    }
};

/// Wrap a compile-time route handler that receives the application context.
pub fn handlerFor(
    comptime H: type,
    comptime f: fn (*H, *Ctx) anyerror!void,
) Handler {
    return .{
        .context = null,
        .call_fn = struct {
            fn call(_: ?*anyopaque, ctx: *Ctx) anyerror!void {
                const app: *H = @ptrCast(@alignCast(ctx.app));
                return f(app, ctx);
            }
        }.call,
    };
}

/// Wrap a plain middleware/handler function.
pub fn handler(comptime f: fn (*Ctx) anyerror!void) Handler {
    return .{
        .context = null,
        .call_fn = struct {
            fn call(_: ?*anyopaque, ctx: *Ctx) anyerror!void {
                return f(ctx);
            }
        }.call,
    };
}

/// Wrap a parameterized middleware/handler. `context` must outlive the router.
pub fn withContext(
    comptime T: type,
    context: *T,
    comptime f: fn (*T, *Ctx) anyerror!void,
) Handler {
    return .{
        .context = context,
        .call_fn = struct {
            fn call(raw: ?*anyopaque, ctx: *Ctx) anyerror!void {
                const typed: *T = @ptrCast(@alignCast(raw.?));
                return f(typed, ctx);
            }
        }.call,
    };
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
