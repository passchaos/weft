const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const response_mod = @import("../response.zig");

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

    pub fn handler(self: *BasicAuth) handler_mod.Handler {
        return handler_mod.withContext(BasicAuth, self, call);
    }

    fn call(self: *BasicAuth, ctx: *ctx_mod.Ctx) anyerror!void {
        const authorization = ctx.header("authorization") orelse
            return self.challenge(ctx);

        const value = std.mem.trim(u8, authorization, " \t");
        var separator: ?usize = null;
        for (value, 0..) |char, index| {
            if (char == ' ' or char == '\t') {
                separator = index;
                break;
            }
        }
        const split = separator orelse return self.challenge(ctx);
        if (!std.ascii.eqlIgnoreCase(value[0..split], "Basic")) {
            return self.challenge(ctx);
        }

        const encoded = std.mem.trim(u8, value[split + 1 ..], " \t");
        if (encoded.len == 0) return self.challenge(ctx);
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(
            encoded,
        ) catch return self.challenge(ctx);
        // Typical credentials fit on the stack; long ones keep the arena
        // fallback.
        var decoded_buffer: [256]u8 = undefined;
        const decoded = if (decoded_len <= decoded_buffer.len)
            decoded_buffer[0..decoded_len]
        else
            try ctx.arena.alloc(u8, decoded_len);
        std.base64.standard.Decoder.decode(decoded, encoded) catch
            return self.challenge(ctx);

        if (!credentialsMatch(decoded, self.username, self.password)) {
            return self.challenge(ctx);
        }

        try ctx.next();
    }

    fn challenge(self: *BasicAuth, ctx: *ctx_mod.Ctx) anyerror!void {
        var realm_buffer: [256]u8 = undefined;
        const challenge_value = std.fmt.bufPrint(
            &realm_buffer,
            "Basic realm=\"{s}\"",
            .{self.realm},
        ) catch try std.fmt.allocPrint(
            ctx.arena,
            "Basic realm=\"{s}\"",
            .{self.realm},
        );
        ctx.setStatus(401);
        try ctx.setHeader("Cache-Control", "no-store");
        try ctx.setHeader("WWW-Authenticate", challenge_value);
        try ctx.text("Unauthorized");
    }
};

/// Compare `username:password` against decoded credentials without building
/// the concatenation. The loop never exits early, preserving the constant-time
/// comparison for equal-length inputs.
fn credentialsMatch(
    decoded: []const u8,
    username: []const u8,
    password: []const u8,
) bool {
    const expected_len = username.len + 1 + password.len;
    var difference: u8 = @intFromBool(decoded.len != expected_len);
    const common = @min(decoded.len, expected_len);
    for (0..common) |index| {
        const expected = if (index < username.len)
            username[index]
        else if (index == username.len)
            ':'
        else
            password[index - username.len - 1];
        difference |= decoded[index] ^ expected;
    }
    return difference == 0;
}

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
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{auth.handler()},
        .final_handler = handler_mod.handler(Final.handle),
    };
    try missing_context.run();
    try std.testing.expectEqual(@as(u16, 401), missing_context.response.status);

    const valid_header = try std.fmt.allocPrint(
        arena.allocator(),
        "basic   {s}",
        .{credentials[0..encoded_len]},
    );
    var valid_headers = [_]netz.http1.Header{.{
        .name = "Authorization",
        .value = valid_header,
    }};
    var valid_request: netz.http1.Request = .{
        .method = .GET,
        .target = "/admin",
        .version = .http_1_1,
        .headers = &valid_headers,
        .body = "",
        .consumed = 0,
    };
    var valid_context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &valid_request,
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{auth.handler()},
        .final_handler = handler_mod.handler(Final.handle),
    };
    try valid_context.run();
    try std.testing.expectEqual(@as(u16, 200), valid_context.response.status);
    try std.testing.expectEqualStrings("secret", valid_context.response.body);
}

test "basic auth rejects a wrong password" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var auth = BasicAuth{ .username = "admin", .password = "secret" };
    var encoded_buffer: [64]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(
        &encoded_buffer,
        "admin:wrong",
    );
    const header = try std.fmt.allocPrint(
        arena.allocator(),
        "Basic {s}",
        .{encoded},
    );

    var headers = [_]netz.http1.Header{.{
        .name = "Authorization",
        .value = header,
    }};
    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/admin",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{auth.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("secret");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 401), context.response.status);
}

test "basic auth compares long credentials without concatenating" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const long_password = "p" ** 400;
    const plain = "admin:" ++ long_password;
    var encoded_buffer: [std.base64.standard.Encoder.calcSize(plain.len)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, plain);
    const header = try std.fmt.allocPrint(
        allocator,
        "Basic {s}",
        .{encoded},
    );
    defer allocator.free(header);

    var headers = [_]netz.http1.Header{.{
        .name = "Authorization",
        .value = header,
    }};
    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/admin",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var auth = BasicAuth{ .username = "admin", .password = long_password };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{auth.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("secret");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 200), context.response.status);

    try std.testing.expect(credentialsMatch(
        "admin:" ++ long_password,
        "admin",
        long_password,
    ));
    try std.testing.expect(!credentialsMatch("admin:wrong", "admin", long_password));
    try std.testing.expect(!credentialsMatch("admin", "admin", long_password));
}
