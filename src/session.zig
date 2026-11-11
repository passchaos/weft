const std = @import("std");
const ctx_mod = @import("ctx.zig");
const cookie_mod = @import("cookie.zig");
const handler_mod = @import("handler.zig");

pub const Store = @import("session/store.zig").Store;
pub const FileStore = @import("session/file_store.zig").FileStore;
pub const SessionId = @import("session/store.zig").SessionId;
pub const SameSite = cookie_mod.SameSite;

pub const Options = struct {
    cookie_name: []const u8 = "weft_session",
    cookie_path: []const u8 = "/",
    cookie_domain: ?[]const u8 = null,
    /// Set this when the listener terminates TLS.
    secure: bool = false,
    http_only: bool = true,
    same_site: ?SameSite = .lax,
    /// Null emits a browser-session cookie while the server-side idle and
    /// absolute deadlines still apply.
    max_age_seconds: ?i64 = null,
};

/// Request-scoped view over one stored session.
///
/// Values are copied into the request arena by the middleware. Mutations mark
/// the session dirty and are written back to the store after the handler
/// chain returns.
pub const Session = struct {
    store: *Store,
    arena: std.mem.Allocator,
    id: SessionId,
    values: Store.Values = .empty,
    is_new: bool = false,
    dirty: bool = false,
    destroy_requested: bool = false,
    rotate_requested: bool = false,

    pub fn get(self: *const Session, name: []const u8) ?[]const u8 {
        return self.values.get(name);
    }

    pub fn set(self: *Session, name: []const u8, value: []const u8) !void {
        if (name.len == 0) return error.InvalidSessionKey;
        const key = try self.arena.dupe(u8, name);
        const stored = try self.arena.dupe(u8, value);
        try self.values.put(self.arena, key, stored);
        self.dirty = true;
    }

    pub fn remove(self: *Session, name: []const u8) bool {
        const removed = self.values.remove(name);
        if (removed) self.dirty = true;
        return removed;
    }

    pub fn setJson(self: *Session, name: []const u8, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(
            self.arena,
            value,
            .{},
        );
        try self.set(name, bytes);
    }

    pub fn getJson(self: *Session, comptime T: type, name: []const u8) !?T {
        const raw = self.get(name) orelse return null;
        return std.json.parseFromSliceLeaky(T, self.arena, raw, .{}) catch
            return error.InvalidSessionValue;
    }

    /// Remove the server-side session and expire the cookie.
    pub fn destroy(self: *Session) void {
        self.destroy_requested = true;
        self.dirty = true;
    }

    /// Move the session to a fresh id on the next response. Call this after a
    /// successful login to prevent session fixation.
    pub fn rotate(self: *Session) void {
        self.rotate_requested = true;
        self.dirty = true;
    }

    pub fn idHex(self: *const Session) [64]u8 {
        return Store.idToHex(self.id);
    }
};

/// Return the session installed by `Middleware`.
pub fn from(ctx: *ctx_mod.Ctx) ?*Session {
    return ctx.get(*Session);
}

pub const Middleware = struct {
    store: *Store,
    options: Options = .{},

    pub fn handler(self: *Middleware) handler_mod.Handler {
        return handler_mod.withContext(Middleware, self, call);
    }

    fn call(self: *Middleware, ctx: *ctx_mod.Ctx) anyerror!void {
        const now = Store.nowNanos(ctx.io);
        var session = Session{
            .store = self.store,
            .arena = ctx.arena,
            .id = undefined,
        };
        var loaded = false;
        if (ctx.cookie(self.options.cookie_name)) |raw| {
            if (Store.idFromHex(raw)) |id| {
                if (try self.store.load(ctx.io, id, ctx.arena, now)) |values| {
                    session.id = id;
                    session.values = values;
                    loaded = true;
                }
            }
        }
        if (!loaded) {
            session.id = Store.randomId(ctx.io);
            session.is_new = true;
            session.dirty = true;
        }
        try ctx.set(*Session, &session);

        ctx.next() catch |err| {
            self.persist(ctx, &session, now) catch {};
            return err;
        };
        try self.persist(ctx, &session, now);
    }

    fn persist(
        self: *Middleware,
        ctx: *ctx_mod.Ctx,
        session: *Session,
        now_ns: i96,
    ) !void {
        if (session.destroy_requested) {
            self.store.remove(ctx.io, session.id);
            try self.clearCookie(ctx);
            return;
        }
        if (session.rotate_requested) {
            const new_id = Store.randomId(ctx.io);
            try self.store.rotate(
                ctx.io,
                session.id,
                new_id,
                &session.values,
                now_ns,
            );
            session.id = new_id;
            try self.writeCookie(ctx, new_id);
            return;
        }
        if (!session.is_new and !session.dirty) {
            if (self.store.touch(ctx.io, session.id, now_ns)) return;
            // The entry expired or was evicted; recreate it below.
        }
        const created = try self.store.save(
            ctx.io,
            session.id,
            &session.values,
            now_ns,
        );
        if (session.is_new or created) {
            try self.writeCookie(ctx, session.id);
        }
    }

    fn writeCookie(
        self: *Middleware,
        ctx: *ctx_mod.Ctx,
        id: SessionId,
    ) !void {
        const hex = Store.idToHex(id);
        try ctx.setCookie(.{
            .name = self.options.cookie_name,
            .value = &hex,
            .path = self.options.cookie_path,
            .domain = self.options.cookie_domain,
            .max_age = self.options.max_age_seconds,
            .secure = self.options.secure,
            .http_only = self.options.http_only,
            .same_site = self.options.same_site,
        });
    }

    fn clearCookie(self: *Middleware, ctx: *ctx_mod.Ctx) !void {
        try ctx.setCookie(.{
            .name = self.options.cookie_name,
            .value = "",
            .path = self.options.cookie_path,
            .domain = self.options.cookie_domain,
            .max_age = 0,
            .secure = self.options.secure,
            .http_only = self.options.http_only,
            .same_site = self.options.same_site,
        });
    }
};

const Header = @import("netz").http1.Header;

test "session middleware persists values across requests" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, .{ .max_sessions = 8 });
    defer store.deinit();
    var middleware = Middleware{ .store = &store };
    const session_handler = middleware.handler();

    const Run = struct {
        fn run(ctx: *ctx_mod.Ctx) anyerror!void {
            const session = from(ctx) orelse return error.MissingSession;
            if (session.get("count")) |raw| {
                const count = try std.fmt.parseInt(u32, raw, 10);
                try session.set(
                    "count",
                    try std.fmt.allocPrint(ctx.arena, "{d}", .{count + 1}),
                );
            } else {
                try session.set("count", "1");
            }
            try ctx.text("ok");
        }
    };

    const First = struct {
        fn run(ctx: *ctx_mod.Ctx) anyerror!void {
            try ctx.next();
            const session = from(ctx).?;
            try std.testing.expectEqualStrings("1", session.get("count").?);
        }
    };

    var first: TestContext = undefined;
    try first.init(
        allocator,
        &.{},
        &.{ session_handler, handler_mod.handler(First.run) },
        handler_mod.handler(Run.run),
    );
    defer first.deinit();
    try first.ctx.run();
    const set_cookie = first.ctx.responseHeader("set-cookie").?;

    var request_headers = [_]Header{.{
        .name = "cookie",
        .value = try cookieHeader(allocator, set_cookie),
    }};
    defer allocator.free(request_headers[0].value);

    const Second = struct {
        fn run(ctx: *ctx_mod.Ctx) anyerror!void {
            try ctx.next();
            const session = from(ctx).?;
            try std.testing.expectEqualStrings("2", session.get("count").?);
        }
    };
    var second: TestContext = undefined;
    try second.init(
        allocator,
        &request_headers,
        &.{ session_handler, handler_mod.handler(Second.run) },
        handler_mod.handler(Run.run),
    );
    defer second.deinit();
    try second.ctx.run();
}

const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    request: @import("netz").http1.Request,
    ctx: ctx_mod.Ctx,

    fn init(
        self: *TestContext,
        allocator: std.mem.Allocator,
        headers: []const Header,
        middleware: []const handler_mod.Handler,
        final_handler: handler_mod.Handler,
    ) !void {
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.request = .{
            .method = .GET,
            .target = "/",
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
            .response = @import("response.zig").Response.init(
                self.arena.allocator(),
                1024,
            ),
            .middleware = middleware,
            .final_handler = final_handler,
        };
    }

    fn deinit(self: *TestContext) void {
        self.arena.deinit();
    }
};

fn cookieHeader(allocator: std.mem.Allocator, set_cookie: []const u8) ![]u8 {
    const end = std.mem.indexOfScalar(u8, set_cookie, ';') orelse
        set_cookie.len;
    return std.fmt.allocPrint(allocator, "{s}", .{set_cookie[0..end]});
}
