const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("../ctx.zig");

/// HTTP Basic authentication middleware with a user-owned credential context.
///
/// The `BasicAuth` value must outlive the router because the handler stores a
/// pointer to it:
///
/// ```zig
/// var auth = weft.middleware.BasicAuth{
///     .username = "admin",
///     .password = "secret",
/// };
/// try router.get("/admin", admin, .{ .middleware = &.{auth.handler()} });
/// ```
pub const BasicAuth = struct {
    username: []const u8,
    password: []const u8,
    realm: []const u8 = "weft",

    pub fn handler(self: *BasicAuth) ctx_mod.Handler {
        return ctx_mod.withContext(BasicAuth, self, call);
    }

    fn call(self: *BasicAuth, ctx: *ctx_mod.Ctx) anyerror!void {
        const authorization = ctx.header("authorization") orelse
            return self.challenge(ctx);
        if (!std.mem.startsWith(u8, authorization, "Basic ")) {
            return self.challenge(ctx);
        }

        const encoded = authorization["Basic ".len..];
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(
            encoded,
        ) catch return self.challenge(ctx);
        const decoded = try ctx.arena.alloc(u8, decoded_len);
        std.base64.standard.Decoder.decode(decoded, encoded) catch
            return self.challenge(ctx);

        const expected = try std.fmt.allocPrint(
            ctx.arena,
            "{s}:{s}",
            .{ self.username, self.password },
        );
        if (!std.mem.eql(u8, decoded, expected)) {
            return self.challenge(ctx);
        }

        try ctx.next();
    }

    fn challenge(self: *BasicAuth, ctx: *ctx_mod.Ctx) anyerror!void {
        ctx.setStatus(401);
        try ctx.setHeader(
            "WWW-Authenticate",
            try std.fmt.allocPrint(
                ctx.arena,
                "Basic realm=\"{s}\"",
                .{self.realm},
            ),
        );
        try ctx.text("Unauthorized");
    }
};

test "basic auth accepts valid credentials and rejects missing ones" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Final = struct {
        fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
            try ctx.text("secret");
        }
    };

    var credentials: [32]u8 = undefined;
    const encoded_len = std.base64.standard.Encoder.calcSize(
        "admin:secret".len,
    );
    _ = std.base64.standard.Encoder.encode(
        credentials[0..encoded_len],
        "admin:secret",
    );
    var auth = BasicAuth{ .username = "admin", .password = "secret" };

    var missing_request: netz.http1.Request = .{
        .method = .GET,
        .target = "/admin",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var missing_context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &missing_request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{auth.handler()},
        .final_handler = ctx_mod.handler(Final.handle),
    };
    try missing_context.run();
    try std.testing.expectEqual(@as(u16, 401), missing_context.response.status);

    const valid_header = try std.fmt.allocPrint(
        arena.allocator(),
        "Basic {s}",
        .{credentials[0..encoded_len]},
    );
    var valid_request: netz.http1.Request = .{
        .method = .GET,
        .target = "/admin",
        .version = .http_1_1,
        .headers = &.{.{
            .name = "Authorization",
            .value = valid_header,
        }},
        .body = "",
        .consumed = 0,
    };
    var valid_context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &valid_request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{auth.handler()},
        .final_handler = ctx_mod.handler(Final.handle),
    };
    try valid_context.run();
    try std.testing.expectEqual(@as(u16, 200), valid_context.response.status);
    try std.testing.expectEqualStrings("secret", valid_context.response.body);
}
