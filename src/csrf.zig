const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const cookie_mod = @import("cookie.zig");
const handler_mod = @import("handler.zig");
const session_mod = @import("session.zig");

pub const SameSite = cookie_mod.SameSite;

pub const Options = struct {
    /// Session key holding the synchronizer token.
    session_key: []const u8 = "__weft_csrf",
    header_name: []const u8 = "x-csrf-token",
    /// Non-HttpOnly cookie so browser clients can copy the token into the
    /// request header. The session copy remains authoritative.
    cookie_name: []const u8 = "weft_csrf",
    cookie_path: []const u8 = "/",
    secure: bool = false,
    same_site: ?SameSite = .lax,
    /// Form field checked when the request is URL-encoded or multipart.
    form_field: []const u8 = "_csrf",
    /// Exact origins accepted for unsafe requests. Empty disables the Origin
    /// check; the token comparison still applies.
    allowed_origins: []const []const u8 = &.{},
    token_bytes: usize = 32,
};

/// CSRF token exposed to handlers for forms or JSON responses.
pub const Token = struct {
    value: []const u8,

    pub fn text(self: Token) []const u8 {
        return self.value;
    }
};

pub fn from(ctx: *ctx_mod.Ctx) ?*const Token {
    return ctx.get(*const Token);
}

/// Session-backed CSRF protection.
///
/// Register this middleware after `weft.session.Middleware`. Safe methods
/// receive a token and cookie; unsafe methods must echo the token in
/// `Options.header_name`. When `allowed_origins` is non-empty, an unsafe
/// request must also carry an exact `Origin` match.
pub const Middleware = struct {
    options: Options = .{},

    pub fn handler(self: *Middleware) handler_mod.Handler {
        return handler_mod.withContext(Middleware, self, call);
    }

    fn call(self: *Middleware, ctx: *ctx_mod.Ctx) anyerror!void {
        if (self.options.token_bytes == 0 or self.options.token_bytes > 64) {
            return error.InvalidCsrfOptions;
        }
        const session = session_mod.from(ctx) orelse
            return error.CsrfRequiresSession;
        const token_value = try self.tokenFor(ctx, session);
        var token = Token{ .value = token_value };
        try ctx.set(*const Token, &token);

        if (isSafeMethod(ctx.method())) {
            try self.ensureCookie(ctx, token_value);
            return ctx.next();
        }

        if (!self.originAllowed(ctx)) return self.reject(ctx);
        const submitted = self.submittedToken(ctx) orelse
            return self.reject(ctx);
        if (!constantTimeEql(
            std.mem.trim(u8, submitted, " \t"),
            token_value,
        )) {
            return self.reject(ctx);
        }
        return ctx.next();
    }

    fn tokenFor(
        self: *Middleware,
        ctx: *ctx_mod.Ctx,
        session: *session_mod.Session,
    ) ![]const u8 {
        if (session.get(self.options.session_key)) |existing| {
            return existing;
        }
        var bytes: [64]u8 = undefined;
        ctx.io.random(bytes[0..self.options.token_bytes]);
        var hex: [128]u8 = undefined;
        const encoded = encodeHex(bytes[0..self.options.token_bytes], &hex);
        try session.set(self.options.session_key, encoded);
        return session.get(self.options.session_key).?;
    }

    fn submittedToken(
        self: *Middleware,
        ctx: *ctx_mod.Ctx,
    ) ?[]const u8 {
        if (ctx.header(self.options.header_name)) |value| {
            return std.mem.trim(u8, value, " \t");
        }
        const content_type = ctx.header("content-type") orelse return null;
        if (std.ascii.startsWithIgnoreCase(
            content_type,
            "application/x-www-form-urlencoded",
        )) {
            const form = ctx.bodyForm() catch return null;
            for (form.pairs) |pair| {
                if (std.mem.eql(u8, pair.name, self.options.form_field)) {
                    return pair.value;
                }
            }
            return null;
        }
        if (std.ascii.startsWithIgnoreCase(
            content_type,
            "multipart/form-data",
        )) {
            const form = ctx.multipart() catch return null;
            const part = form.part(self.options.form_field) orelse return null;
            return part.data;
        }
        return null;
    }

    fn ensureCookie(
        self: *Middleware,
        ctx: *ctx_mod.Ctx,
        token: []const u8,
    ) !void {
        if (ctx.cookie(self.options.cookie_name)) |existing| {
            if (std.mem.eql(u8, existing, token)) return;
        }
        try ctx.setCookie(.{
            .name = self.options.cookie_name,
            .value = token,
            .path = self.options.cookie_path,
            .secure = self.options.secure,
            .http_only = false,
            .same_site = self.options.same_site,
        });
    }

    fn originAllowed(self: *Middleware, ctx: *ctx_mod.Ctx) bool {
        if (self.options.allowed_origins.len == 0) return true;
        const origin = ctx.header("origin") orelse return false;
        for (self.options.allowed_origins) |allowed| {
            if (std.mem.eql(u8, origin, allowed)) return true;
        }
        return false;
    }

    fn reject(self: *Middleware, ctx: *ctx_mod.Ctx) !void {
        _ = self;
        ctx.setStatus(403);
        try ctx.text("CSRF token missing or invalid");
    }
};

fn isSafeMethod(method: netz.http1.Method) bool {
    return switch (method) {
        .GET, .HEAD, .OPTIONS, .TRACE => true,
        else => false,
    };
}

fn encodeHex(input: []const u8, output: []u8) []const u8 {
    const digits = "0123456789abcdef";
    std.debug.assert(output.len >= input.len * 2);
    for (input, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 15];
    }
    return output[0 .. input.len * 2];
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    for (a, b) |left, right| difference |= left ^ right;
    return difference == 0;
}

test "csrf requires a token on unsafe methods and accepts a valid header" {
    const allocator = std.testing.allocator;
    var store = try session_mod.Store.init(allocator, .{ .max_sessions = 8 });
    defer store.deinit();
    var session_middleware = session_mod.Middleware{ .store = &store };
    var csrf_middleware = Middleware{};
    const session_handler = session_middleware.handler();
    const csrf_handler = csrf_middleware.handler();

    const Run = struct {
        fn run(ctx: *ctx_mod.Ctx) anyerror!void {
            const token = from(ctx) orelse return error.MissingCsrfToken;
            try ctx.text(token.value);
        }
    };

    var get: TestContext = undefined;
    try get.init(
        allocator,
        .GET,
        &.{},
        "",
        &.{ session_handler, csrf_handler },
        handler_mod.handler(Run.run),
    );
    defer get.deinit();
    try get.ctx.run();
    const token = try allocator.dupe(u8, get.ctx.response.body);
    defer allocator.free(token);
    try std.testing.expect(token.len == 64);
    var session_cookie_header: ?[]const u8 = null;
    for (get.ctx.response.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "set-cookie") and
            std.mem.startsWith(u8, header.value, "weft_session="))
        {
            session_cookie_header = header.value;
            break;
        }
    }
    const session_cookie = try cookieValue(
        allocator,
        session_cookie_header orelse return error.MissingSessionCookie,
    );
    defer allocator.free(session_cookie);

    var headers = [_]netz.http1.Header{
        .{ .name = "cookie", .value = try std.fmt.allocPrint(
            allocator,
            "{s}",
            .{session_cookie},
        ) },
        .{ .name = "x-csrf-token", .value = token },
    };
    defer allocator.free(headers[0].value);

    var post: TestContext = undefined;
    try post.init(
        allocator,
        .POST,
        &headers,
        "",
        &.{ session_handler, csrf_handler },
        handler_mod.handler(Run.run),
    );
    defer post.deinit();
    try post.ctx.run();
    try std.testing.expectEqual(@as(u16, 200), post.ctx.response.status);
    try std.testing.expectEqualStrings(token, post.ctx.response.body);

    var rejected: TestContext = undefined;
    try rejected.init(
        allocator,
        .POST,
        headers[0..1],
        "",
        &.{ session_handler, csrf_handler },
        handler_mod.handler(Run.run),
    );
    defer rejected.deinit();
    try rejected.ctx.run();
    try std.testing.expectEqual(@as(u16, 403), rejected.ctx.response.status);

    const form_body = try std.fmt.allocPrint(allocator, "_csrf={s}", .{token});
    defer allocator.free(form_body);
    var form_headers = [_]Header{
        .{ .name = "cookie", .value = session_cookie },
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    };
    var form_post: TestContext = undefined;
    try form_post.init(
        allocator,
        .POST,
        &form_headers,
        form_body,
        &.{ session_handler, csrf_handler },
        handler_mod.handler(Run.run),
    );
    defer form_post.deinit();
    try form_post.ctx.run();
    try std.testing.expectEqual(@as(u16, 200), form_post.ctx.response.status);
}

const Header = netz.http1.Header;

const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    request: netz.http1.Request,
    ctx: ctx_mod.Ctx,

    fn init(
        self: *TestContext,
        allocator: std.mem.Allocator,
        method: netz.http1.Method,
        headers: []const Header,
        body: []const u8,
        middleware: []const handler_mod.Handler,
        final_handler: handler_mod.Handler,
    ) !void {
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.request = .{
            .method = method,
            .target = "/",
            .version = .http_1_1,
            .headers = @constCast(headers),
            .body = body,
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

fn cookieValue(allocator: std.mem.Allocator, set_cookie: []const u8) ![]u8 {
    const end = std.mem.indexOfScalar(u8, set_cookie, ';') orelse
        set_cookie.len;
    return allocator.dupe(u8, set_cookie[0..end]);
}
