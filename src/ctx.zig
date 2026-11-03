const std = @import("std");
const netz = @import("netz");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const query_mod = @import("query.zig");
const cookie_mod = @import("cookie.zig");
const stream_mod = @import("stream.zig");

pub const Response = response_mod.Response;
pub const Limits = limits_mod.Limits;
pub const QueryPair = query_mod.Pair;
pub const SetCookie = cookie_mod.SetCookie;
pub const StreamBody = stream_mod.Body;
pub const StreamWriter = stream_mod.Writer;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// Transport/version metadata for the current request.
pub const Protocol = enum {
    http_1_0,
    http_1_1,
    http_2,
    http_3,
};

pub const ClientInfo = struct {
    /// Peer address when the adapter can expose one.
    address: ?std.Io.net.IpAddress = null,
    protocol: Protocol = .http_1_1,
    tls: bool = false,
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
    client_info: ClientInfo = .{},
    query: []const u8 = "",
    /// Decoded query pairs, bounded by `limits.max_query_params`.
    query_params: []const QueryPair = &.{},
    /// Decoded path captures. `Router` produces raw captures; the server
    /// decodes them before invoking handlers.
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

    pub fn protocol(self: *const Ctx) Protocol {
        return self.client_info.protocol;
    }

    pub fn clientAddress(self: *const Ctx) ?std.Io.net.IpAddress {
        return self.client_info.address;
    }

    pub fn isTls(self: *const Ctx) bool {
        return self.client_info.tls;
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

    /// Decode any `Content-Encoding` layers using the request arena.
    ///
    /// The decoded output is bounded by `Limits.max_body_bytes`. An absent or
    /// `identity` encoding borrows the original body without allocating.
    pub fn decodedBody(self: *Ctx) ![]const u8 {
        const decoded = self.request.decodeContentAlloc(
            self.arena,
            self.limits.max_body_bytes,
        ) catch |err| switch (err) {
            error.UnsupportedContentEncoding => return error.UnsupportedMediaType,
            error.DecodedBodyTooLarge,
            error.EncodedBodyTooLarge,
            => return error.PayloadTooLarge,
            error.InvalidContentEncoding,
            error.TooManyContentEncodings,
            error.InvalidDecoderState,
            error.AliasedBuffers,
            => return error.BadRequest,
            else => return err,
        };
        return decoded.bytes;
    }

    pub fn param(self: *const Ctx, name: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    /// Look up the first decoded query value. Repeated keys resolve to the
    /// first occurrence; `queryPairs` exposes the full ordered list.
    pub fn queryParam(self: *const Ctx, name: []const u8) ?[]const u8 {
        if (self.query_params.len > 0) {
            for (self.query_params) |pair| {
                if (std.mem.eql(u8, pair.name, name)) return pair.value;
            }
            return null;
        }

        // Fallback for manually constructed contexts that only set `query`.
        var pairs = std.mem.splitScalar(u8, self.query, '&');
        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            if (std.mem.eql(u8, pair[0..equals], name)) {
                return query_mod.decodeComponent(
                    self.arena,
                    pair[equals + 1 ..],
                    true,
                ) catch null;
            }
        }
        return null;
    }

    /// All decoded query pairs in wire order.
    pub fn queryPairs(self: *const Ctx) []const QueryPair {
        return self.query_params;
    }

    /// Parse the decoded request body as JSON using the request arena.
    pub fn bodyJson(self: *Ctx, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(
            T,
            self.arena,
            try self.decodedBody(),
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
    }

    /// Parse an `application/x-www-form-urlencoded` request body. The returned
    /// query owns arena allocations for the request lifetime.
    pub fn bodyForm(self: *Ctx) !query_mod.Query {
        const media_type = "application/x-www-form-urlencoded";
        const content_type = self.header("content-type") orelse
            return error.UnsupportedMediaType;
        if (!std.ascii.startsWithIgnoreCase(content_type, media_type)) {
            return error.UnsupportedMediaType;
        }
        if (content_type.len > media_type.len) {
            const delimiter = content_type[media_type.len];
            if (delimiter != ';' and delimiter != ' ' and delimiter != '\t') {
                return error.UnsupportedMediaType;
            }
        }
        return query_mod.parse(
            self.arena,
            try self.decodedBody(),
            self.limits.max_query_params,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadRequest,
        };
    }

    /// Read a request cookie by name. Cookie names are case-sensitive.
    pub fn cookie(self: *const Ctx, name: []const u8) ?[]const u8 {
        return cookie_mod.find(self.request.headers, name);
    }

    /// Append a `Set-Cookie` response field.
    pub fn setCookie(self: *Ctx, set_cookie: SetCookie) !void {
        try self.addHeader(
            "Set-Cookie",
            try cookie_mod.serialize(self.arena, set_cookie),
        );
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

    /// Append a header field, preserving duplicates. Intended for list-valued
    /// fields such as `Set-Cookie`.
    pub fn addHeader(
        self: *Ctx,
        name: []const u8,
        value: []const u8,
    ) !void {
        try self.response.appendHeader(name, value);
    }

    pub fn responseHeader(self: *const Ctx, name: []const u8) ?[]const u8 {
        return self.response.header(name);
    }

    pub fn text(self: *Ctx, value: []const u8) !void {
        try self.response.text(value);
    }

    pub fn redirect(self: *Ctx, status: u16, location: []const u8) !void {
        if (status < 300 or status > 399) return error.InvalidRedirectStatus;
        self.setStatus(status);
        try self.setHeader("Location", location);
    }

    pub fn json(self: *Ctx, value: anytype) !void {
        try self.response.json(value);
    }

    /// Select an incremental body producer. The producer runs after the
    /// handler returns and may write at most `Limits.max_response_bytes`.
    pub fn stream(self: *Ctx, stream_body: StreamBody) !void {
        if (self.response.stream != null) return error.StreamAlreadySet;
        if (self.response.body.len != 0 or self.response.body_owned) {
            return error.BodyAlreadySet;
        }
        if (stream_body.length) |length| {
            if (length > self.limits.max_response_bytes) {
                return error.ResponseTooLarge;
            }
        }
        self.response.stream = stream_body;
        self.response.committed = true;
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
