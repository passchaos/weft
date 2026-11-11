const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const response_mod = @import("../response.zig");

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
    /// Optional CSP template. Every `{nonce}` is replaced with a fresh
    /// Base64URL nonce exposed through `nonce(ctx)`.
    content_security_policy: ?[]const u8 = null,
    csp_nonce_bytes: usize = 16,

    pub fn handler(self: *SecurityHeaders) handler_mod.Handler {
        return handler_mod.withContext(SecurityHeaders, self, call);
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
        if (self.content_security_policy) |policy| {
            if (std.mem.indexOf(u8, policy, "{nonce}") != null) {
                if (self.csp_nonce_bytes == 0 or self.csp_nonce_bytes > 32) {
                    return error.InvalidCspOptions;
                }
                var bytes: [32]u8 = undefined;
                ctx.io.random(bytes[0..self.csp_nonce_bytes]);
                const nonce_value = try encodeNonce(
                    ctx.arena,
                    bytes[0..self.csp_nonce_bytes],
                );
                var local = Nonce{ .value = nonce_value };
                try ctx.set(*const Nonce, &local);
                try ctx.setHeader(
                    "Content-Security-Policy",
                    try renderPolicy(ctx.arena, policy, nonce_value),
                );
            } else {
                try setIfAbsent(
                    ctx,
                    "Content-Security-Policy",
                    policy,
                );
            }
        }
        try ctx.next();
    }
};

/// CSP nonce exposed to handlers after `SecurityHeaders` runs.
pub const Nonce = struct {
    value: []const u8,

    pub fn text(self: Nonce) []const u8 {
        return self.value;
    }
};

pub fn nonce(ctx: *ctx_mod.Ctx) ?*const Nonce {
    return ctx.get(*const Nonce);
}

/// Apply the default security-header set.
pub fn securityHeaders(ctx: *ctx_mod.Ctx) anyerror!void {
    var defaults = SecurityHeaders{};
    return defaults.call(ctx);
}

fn encodeNonce(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]const u8 {
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const output = try allocator.alloc(u8, size);
    return std.base64.url_safe_no_pad.Encoder.encode(output, bytes);
}

fn renderPolicy(
    allocator: std.mem.Allocator,
    policy: []const u8,
    nonce_value: []const u8,
) ![]const u8 {
    const marker = "{nonce}";
    var output = std.ArrayListUnmanaged(u8).empty;
    errdefer output.deinit(allocator);
    var remaining = policy;
    while (std.mem.indexOf(u8, remaining, marker)) |index| {
        try output.appendSlice(allocator, remaining[0..index]);
        try output.appendSlice(allocator, nonce_value);
        remaining = remaining[index + marker.len ..];
    }
    try output.appendSlice(allocator, remaining);
    return output.toOwnedSlice(allocator);
}

fn setIfAbsent(
    ctx: *ctx_mod.Ctx,
    name: []const u8,
    value: ?[]const u8,
) !void {
    const header_value = value orelse return;
    try ctx.response.setHeaderIfAbsent(name, header_value);
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
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{handler_mod.handler(securityHeaders)},
        .final_handler = handler_mod.handler(struct {
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

test "security headers render a CSP nonce" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = SecurityHeaders{
        .content_security_policy = "default-src 'self'; script-src 'nonce-{nonce}'",
    };
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
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{headers.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text(nonce(ctx).?.value);
            }
        }.handle),
    };
    try context.run();

    const policy = context.response.header("content-security-policy").?;
    const token = context.response.body;
    try std.testing.expect(token.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, policy, token) != null);
}
