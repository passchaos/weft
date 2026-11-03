const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("../ctx.zig");
const vary = @import("../vary.zig");

/// Cross-Origin Resource Sharing policy.
///
/// `allowed_origins` is an exact-match allow list. Set `allow_any_origin` to
/// reflect every origin with `*`; credential-bearing requests always reflect
/// the concrete origin because the CORS specification forbids `*` with
/// credentials.
pub const Cors = struct {
    allowed_origins: []const []const u8 = &.{},
    allow_any_origin: bool = false,
    allow_credentials: bool = false,
    allow_methods: []const []const u8 = &.{
        "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS",
    },
    /// Empty means reflect the requested `Access-Control-Request-Headers`.
    allow_headers: []const []const u8 = &.{},
    expose_headers: []const []const u8 = &.{},
    max_age_seconds: ?u32 = null,

    pub fn handler(self: *Cors) ctx_mod.Handler {
        return ctx_mod.withContext(Cors, self, call);
    }

    fn call(self: *Cors, ctx: *ctx_mod.Ctx) anyerror!void {
        // The response depends on `Origin` even when the request omits it or
        // the origin is rejected, so shared caches must key on it.
        try vary.add(ctx, "Origin");

        const origin = ctx.header("origin") orelse {
            try ctx.next();
            return;
        };
        if (!self.originAllowed(origin)) {
            try ctx.next();
            return;
        }

        if (self.allow_any_origin and !self.allow_credentials) {
            try ctx.setHeader("Access-Control-Allow-Origin", "*");
        } else {
            try ctx.setHeader("Access-Control-Allow-Origin", origin);
        }
        if (self.allow_credentials) {
            try ctx.setHeader("Access-Control-Allow-Credentials", "true");
        }

        if (ctx.method() == .OPTIONS and
            ctx.header("access-control-request-method") != null)
        {
            return self.preflight(ctx);
        }

        if (self.expose_headers.len > 0) {
            try ctx.setHeader(
                "Access-Control-Expose-Headers",
                try std.mem.join(ctx.arena, ", ", self.expose_headers),
            );
        }
        try ctx.next();
    }

    fn preflight(self: *Cors, ctx: *ctx_mod.Ctx) !void {
        try vary.add(ctx, "Access-Control-Request-Method");

        const requested_method = ctx.header("access-control-request-method").?;
        if (!self.methodAllowed(requested_method)) {
            ctx.setStatus(403);
            try ctx.text("CORS method not allowed");
            return;
        }

        try ctx.setHeader(
            "Access-Control-Allow-Methods",
            try std.mem.join(ctx.arena, ", ", self.allow_methods),
        );

        if (ctx.header("access-control-request-headers")) |requested| {
            try vary.add(ctx, "Access-Control-Request-Headers");
            if (self.allow_headers.len == 0) {
                try ctx.setHeader("Access-Control-Allow-Headers", requested);
            } else {
                if (!self.requestedHeadersAllowed(requested)) {
                    ctx.setStatus(403);
                    try ctx.text("CORS header not allowed");
                    return;
                }
                try ctx.setHeader(
                    "Access-Control-Allow-Headers",
                    try std.mem.join(ctx.arena, ", ", self.allow_headers),
                );
            }
        } else if (self.allow_headers.len > 0) {
            try ctx.setHeader(
                "Access-Control-Allow-Headers",
                try std.mem.join(ctx.arena, ", ", self.allow_headers),
            );
        }

        if (self.max_age_seconds) |seconds| {
            try ctx.setHeader(
                "Access-Control-Max-Age",
                try std.fmt.allocPrint(ctx.arena, "{d}", .{seconds}),
            );
        }
        if (self.expose_headers.len > 0) {
            try ctx.setHeader(
                "Access-Control-Expose-Headers",
                try std.mem.join(ctx.arena, ", ", self.expose_headers),
            );
        }

        ctx.setStatus(204);
    }

    fn originAllowed(self: *const Cors, origin: []const u8) bool {
        if (self.allow_any_origin) return true;
        for (self.allowed_origins) |allowed| {
            if (std.mem.eql(u8, allowed, origin)) return true;
        }
        return false;
    }

    fn methodAllowed(self: *const Cors, method: []const u8) bool {
        for (self.allow_methods) |allowed| {
            if (std.mem.eql(u8, allowed, method)) return true;
        }
        return false;
    }

    fn requestedHeadersAllowed(
        self: *const Cors,
        requested: []const u8,
    ) bool {
        var iterator = std.mem.splitScalar(u8, requested, ',');
        while (iterator.next()) |part| {
            const name = std.mem.trim(u8, part, " \t");
            if (name.len == 0) continue;
            var allowed = false;
            for (self.allow_headers) |candidate| {
                if (std.ascii.eqlIgnoreCase(candidate, name)) {
                    allowed = true;
                    break;
                }
            }
            if (!allowed) return false;
        }
        return true;
    }
};

test "cors reflects allowed origins and answers preflight" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const origins = [_][]const u8{"https://app.example"};
    var cors = Cors{
        .allowed_origins = &origins,
        .allow_credentials = true,
    };

    var headers = [_]netz.http1.Header{
        .{ .name = "Origin", .value = "https://app.example" },
        .{ .name = "Access-Control-Request-Method", .value = "POST" },
        .{ .name = "Access-Control-Request-Headers", .value = "content-type" },
    };
    var request: netz.http1.Request = .{
        .method = .OPTIONS,
        .target = "/api",
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
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{cors.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("route");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 204), context.response.status);
    try std.testing.expectEqualStrings(
        "https://app.example",
        context.response.header("access-control-allow-origin").?,
    );
    try std.testing.expectEqualStrings(
        "true",
        context.response.header("access-control-allow-credentials").?,
    );
    try std.testing.expectEqualStrings(
        "content-type",
        context.response.header("access-control-allow-headers").?,
    );
    try std.testing.expect(
        context.response.header("access-control-allow-methods").?.len > 0,
    );
    const preflight_vary = context.response.header("vary").?;
    try std.testing.expect(std.mem.indexOf(u8, preflight_vary, "Origin") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        preflight_vary,
        "Access-Control-Request-Method",
    ) != null);
}

test "cors leaves disallowed origins without cors headers" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const origins = [_][]const u8{"https://app.example"};
    var cors = Cors{ .allowed_origins = &origins };

    var headers = [_]netz.http1.Header{
        .{ .name = "Origin", .value = "https://evil.example" },
    };
    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/",
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
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{cors.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings("ok", context.response.body);
    try std.testing.expect(
        context.response.header("access-control-allow-origin") == null,
    );
    // Rejected origins still vary, so a shared cache cannot reuse a
    // non-CORS response for an allowed origin.
    try std.testing.expectEqualStrings(
        "Origin",
        context.response.header("vary").?,
    );
}

test "cors varies on origin even without an Origin header" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const origins = [_][]const u8{"https://app.example"};
    var cors = Cors{ .allowed_origins = &origins };

    var headers = [_]netz.http1.Header{};
    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/",
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
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{cors.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings("ok", context.response.body);
    try std.testing.expectEqualStrings(
        "Origin",
        context.response.header("vary").?,
    );
}

test "cors rejects requested headers outside the allow list" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const origins = [_][]const u8{"https://app.example"};
    const allowed_headers = [_][]const u8{"content-type"};
    var cors = Cors{
        .allowed_origins = &origins,
        .allow_headers = &allowed_headers,
    };

    var headers = [_]netz.http1.Header{
        .{ .name = "Origin", .value = "https://app.example" },
        .{ .name = "Access-Control-Request-Method", .value = "POST" },
        .{ .name = "Access-Control-Request-Headers", .value = "content-type, x-evil" },
    };
    var request: netz.http1.Request = .{
        .method = .OPTIONS,
        .target = "/api",
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
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{cors.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("route");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 403), context.response.status);
    try std.testing.expectEqualStrings(
        "CORS header not allowed",
        context.response.body,
    );
}
