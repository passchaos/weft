const std = @import("std");
const ctx_mod = @import("../ctx.zig");

/// Baseline browser security headers. Every field is optional so an
/// application can opt out or override a value before this middleware runs.
pub const SecurityHeaders = struct {
    content_type_options: ?[]const u8 = "nosniff",
    frame_options: ?[]const u8 = "DENY",
    referrer_policy: ?[]const u8 = "no-referrer",
    permissions_policy: ?[]const u8 =
        "camera=(), microphone=(), geolocation=()",
    cross_origin_opener_policy: ?[]const u8 = "same-origin",
    /// Set only for HTTPS deployments; weft does not infer transport security
    /// from the cleartext HTTP/1 adapter.
    strict_transport_security: ?[]const u8 = null,

    pub fn handler(self: *SecurityHeaders) ctx_mod.Handler {
        return ctx_mod.withContext(SecurityHeaders, self, call);
    }

    fn call(self: *SecurityHeaders, ctx: *ctx_mod.Ctx) anyerror!void {
        try setIfAbsent(ctx, "X-Content-Type-Options", self.content_type_options);
        try setIfAbsent(ctx, "X-Frame-Options", self.frame_options);
        try setIfAbsent(ctx, "Referrer-Policy", self.referrer_policy);
        try setIfAbsent(ctx, "Permissions-Policy", self.permissions_policy);
        try setIfAbsent(
            ctx,
            "Cross-Origin-Opener-Policy",
            self.cross_origin_opener_policy,
        );
        try setIfAbsent(
            ctx,
            "Strict-Transport-Security",
            self.strict_transport_security,
        );
        try ctx.next();
    }
};

/// Apply the default security-header set.
pub fn securityHeaders(ctx: *ctx_mod.Ctx) anyerror!void {
    var defaults = SecurityHeaders{};
    return defaults.call(ctx);
}

fn setIfAbsent(
    ctx: *ctx_mod.Ctx,
    name: []const u8,
    value: ?[]const u8,
) !void {
    const header_value = value orelse return;
    if (ctx.responseHeader(name) == null) {
        try ctx.setHeader(name, header_value);
    }
}

test "security headers are applied and can be overridden" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
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
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{ctx_mod.handler(securityHeaders)},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("X-Frame-Options", "SAMEORIGIN");
                try ctx.text("ok");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "nosniff",
        context.response.header("x-content-type-options").?,
    );
    try std.testing.expectEqualStrings(
        "SAMEORIGIN",
        context.response.header("x-frame-options").?,
    );
    try std.testing.expectEqualStrings(
        "no-referrer",
        context.response.header("referrer-policy").?,
    );
}
