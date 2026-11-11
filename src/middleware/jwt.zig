const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const jwt = @import("../jwt.zig");

/// RFC 6750 Bearer-token authentication backed by `weft.jwt`.
///
/// Successful verification stores a `*jwt.Verified` local. Handlers read it
/// with `from(ctx)`; the token remains valid until the handler chain returns.
pub const Bearer = struct {
    options: jwt.VerifyOptions,
    realm: []const u8 = "weft",
    /// When false, a missing credential continues without a `Verified` local;
    /// an invalid credential still returns 401.
    required: bool = true,
    /// CORS preflight requests usually omit credentials.
    skip_options: bool = true,

    pub fn handler(self: *Bearer) handler_mod.Handler {
        return handler_mod.withContext(Bearer, self, call);
    }

    fn call(self: *Bearer, ctx: *ctx_mod.Ctx) anyerror!void {
        if (self.skip_options) switch (ctx.method()) {
            .OPTIONS => return ctx.next(),
            else => {},
        };

        const authorization = ctx.header("authorization") orelse {
            if (!self.required) return ctx.next();
            return self.challenge(ctx);
        };
        const token = parseBearer(authorization) orelse {
            if (!self.required) return ctx.next();
            return self.challenge(ctx);
        };

        var options = self.options;
        options.io = ctx.io;
        var verified = jwt.verify(ctx.arena, token, options) catch {
            return self.challenge(ctx);
        };
        try ctx.set(*const jwt.Verified, &verified);
        ctx.next() catch |err| {
            verified.deinit();
            return err;
        };
        verified.deinit();
    }

    fn challenge(self: *Bearer, ctx: *ctx_mod.Ctx) !void {
        ctx.setStatus(401);
        try ctx.setHeader(
            "WWW-Authenticate",
            try std.fmt.allocPrint(
                ctx.arena,
                "Bearer realm=\"{s}\"",
                .{self.realm},
            ),
        );
        try ctx.text("Unauthorized");
    }
};

/// Return the verified token installed by `Bearer`.
pub fn from(ctx: *ctx_mod.Ctx) ?*const jwt.Verified {
    return ctx.get(*const jwt.Verified);
}

fn parseBearer(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    const separator = std.mem.indexOfScalar(u8, trimmed, ' ') orelse
        return null;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..separator], "bearer")) return null;
    const token = std.mem.trim(u8, trimmed[separator + 1 ..], " \t");
    if (token.len == 0) return null;
    return token;
}

test "bearer middleware verifies a token and rejects missing credentials" {
    const allocator = std.testing.allocator;
    const key = "0123456789abcdef0123456789abcdef";
    const token = try jwt.encode(
        allocator,
        .{ .sub = "user-7", .exp = @as(i64, 2_000_000_000) },
        .{ .key = .{ .hs256 = key } },
    );
    defer allocator.free(token);
    const authorization = try std.fmt.allocPrint(
        allocator,
        "Bearer {s}",
        .{token},
    );
    defer allocator.free(authorization);

    var middleware = Bearer{ .options = .{ .key = .{ .hs256 = key } } };
    const bearer_handler = middleware.handler();

    const Run = struct {
        fn run(ctx: *ctx_mod.Ctx) anyerror!void {
            const verified = from(ctx) orelse return error.MissingClaims;
            try ctx.text(verified.claimString("sub").?);
        }
    };

    var headers = [_]@import("netz").http1.Header{.{
        .name = "authorization",
        .value = authorization,
    }};
    var accepted: TestContext = undefined;
    try accepted.init(
        allocator,
        &headers,
        &.{bearer_handler},
        handler_mod.handler(Run.run),
    );
    defer accepted.deinit();
    try accepted.ctx.run();
    try std.testing.expectEqual(@as(u16, 200), accepted.ctx.response.status);
    try std.testing.expectEqualStrings("user-7", accepted.ctx.response.body);

    var missing: TestContext = undefined;
    try missing.init(
        allocator,
        &.{},
        &.{bearer_handler},
        handler_mod.handler(Run.run),
    );
    defer missing.deinit();
    try missing.ctx.run();
    try std.testing.expectEqual(@as(u16, 401), missing.ctx.response.status);
}

const Header = @import("netz").http1.Header;

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
            .response = @import("../response.zig").Response.init(
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
