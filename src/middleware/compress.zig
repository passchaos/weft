const std = @import("std");
const ctx_mod = @import("../ctx.zig");

const flate = std.compress.flate;

/// Response compression with bounded, content-type-aware negotiation.
///
/// The middleware compresses only responses that already have a complete body
/// and are larger than `min_bytes`. It never compresses a response that
/// already selected a `Content-Encoding` or asked for `no-transform`.
pub const Compress = struct {
    min_bytes: usize = 1024,
    level: flate.Compress.Options = .default,
    enable_gzip: bool = true,
    enable_deflate: bool = true,

    pub fn handler(self: *Compress) ctx_mod.Handler {
        return ctx_mod.withContext(Compress, self, call);
    }

    fn call(self: *Compress, ctx: *ctx_mod.Ctx) anyerror!void {
        const negotiation = self.negotiate(ctx);
        try addVary(ctx);
        try ctx.next();

        const response = &ctx.response;
        if (response.hasHeader("content-encoding")) return;
        if (noTransform(response.header("cache-control"))) return;

        switch (negotiation) {
            .identity => return,
            .not_acceptable => {
                response.reset();
                response.setStatus(406);
                response.text("Not Acceptable") catch {};
                try addVary(ctx);
                return;
            },
            .coding => |coding| {
                if (response.body.len < self.min_bytes) return;
                if (!compressible(response.header("content-type"))) return;

                const compressed = compressBody(
                    ctx.arena,
                    response.body,
                    coding,
                    self.level,
                ) catch return;
                response.setHeader(
                    "Content-Encoding",
                    coding.headerValue(),
                ) catch {
                    ctx.arena.free(compressed);
                    return;
                };
                response.setBody(compressed) catch {
                    _ = response.removeHeader("content-encoding");
                    ctx.arena.free(compressed);
                    return;
                };
            },
        }
    }

    fn negotiate(self: *const Compress, ctx: *const ctx_mod.Ctx) Negotiation {
        const header = ctx.header("accept-encoding") orelse return .identity;

        var gzip_quality: ?f64 = null;
        var deflate_quality: ?f64 = null;
        var identity_quality: ?f64 = null;
        var wildcard_quality: ?f64 = null;
        var saw_known = false;

        var parts = std.mem.splitScalar(u8, header, ',');
        while (parts.next()) |part| {
            const item = std.mem.trim(u8, part, " \t");
            if (item.len == 0) continue;
            const semicolon = std.mem.indexOfScalar(u8, item, ';');
            const coding = std.mem.trim(
                u8,
                if (semicolon) |index| item[0..index] else item,
                " \t",
            );
            const q = if (semicolon) |index|
                quality(item[index + 1 ..]) orelse 1.0
            else
                1.0;

            if (std.ascii.eqlIgnoreCase(coding, "gzip") or
                std.ascii.eqlIgnoreCase(coding, "x-gzip"))
            {
                gzip_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "deflate")) {
                deflate_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "identity")) {
                identity_quality = q;
            } else if (std.mem.eql(u8, coding, "*")) {
                wildcard_quality = q;
            } else {
                continue;
            }
            saw_known = true;
        }

        if (!saw_known) return .identity;

        const wildcard = wildcard_quality orelse 0.0;
        const gzip_q = if (self.enable_gzip)
            gzip_quality orelse wildcard
        else
            0.0;
        const deflate_q = if (self.enable_deflate)
            deflate_quality orelse wildcard
        else
            0.0;
        const identity_q = identity_quality orelse
            (if (wildcard_quality != null and wildcard == 0)
                @as(f64, 0.0)
            else
                @as(f64, 1.0));

        var best: ?Coding = null;
        var best_quality: f64 = 0;
        if (gzip_q > 0 and gzip_q > best_quality) {
            best = .gzip;
            best_quality = gzip_q;
        }
        if (deflate_q > 0 and deflate_q > best_quality) {
            best = .deflate;
            best_quality = deflate_q;
        }
        if (best) |coding| return .{ .coding = coding };
        if (identity_q > 0) return .identity;
        return .not_acceptable;
    }
};

const Coding = enum {
    gzip,
    deflate,

    fn headerValue(self: Coding) []const u8 {
        return switch (self) {
            .gzip => "gzip",
            .deflate => "deflate",
        };
    }

    fn container(self: Coding) flate.Container {
        return switch (self) {
            .gzip => .gzip,
            .deflate => .zlib,
        };
    }
};

const Negotiation = union(enum) {
    identity,
    not_acceptable,
    coding: Coding,
};

/// Apply default gzip/deflate negotiation.
pub fn compress(ctx: *ctx_mod.Ctx) anyerror!void {
    var defaults = Compress{};
    return defaults.call(ctx);
}

fn compressBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    coding: Coding,
    level: flate.Compress.Options,
) ![]const u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    defer output.deinit();

    var window: [flate.max_window_len]u8 = undefined;
    var encoder = try flate.Compress.init(
        &output.writer,
        &window,
        coding.container(),
        level,
    );
    try encoder.writer.writeAll(body);
    try encoder.finish();

    return output.toOwnedSlice();
}

fn noTransform(cache_control: ?[]const u8) bool {
    const value = cache_control orelse return false;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, part, " \t"),
            "no-transform",
        )) return true;
    }
    return false;
}

fn quality(params: []const u8) ?f64 {
    var parts = std.mem.splitScalar(u8, params, ';');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (!std.ascii.startsWithIgnoreCase(trimmed, "q=")) continue;
        const value = std.mem.trim(u8, trimmed[2..], " \t");
        return std.fmt.parseFloat(f64, value) catch null;
    }
    return null;
}

fn compressible(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    inline for (.{
        "text/",
        "application/json",
        "application/javascript",
        "application/x-javascript",
        "application/xml",
        "application/xhtml+xml",
        "image/svg+xml",
        "application/x-www-form-urlencoded",
    }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(value, prefix)) return true;
    }
    return false;
}

fn addVary(ctx: *ctx_mod.Ctx) !void {
    if (ctx.responseHeader("vary")) |existing| {
        if (containsToken(existing, "accept-encoding")) return;
        const combined = try std.fmt.allocPrint(
            ctx.arena,
            "{s}, Accept-Encoding",
            .{existing},
        );
        try ctx.setHeader("Vary", combined);
    } else {
        try ctx.setHeader("Vary", "Accept-Encoding");
    }
}

fn containsToken(value: []const u8, token: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, part, " \t"),
            token,
        )) return true;
    }
    return false;
}

test "compress middleware gzips an accepted response" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip, deflate",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var gzip_middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{gzip_middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "gzip",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(context.response.body.len < 4096);
    try std.testing.expectEqual(@as(u8, 0x1f), context.response.body[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), context.response.body[1]);
    try std.testing.expect(
        containsToken(context.response.header("vary").?, "accept-encoding"),
    );
}

test "compress middleware honors q=0 and small bodies" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip;q=0, identity",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var gzip_middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{gzip_middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
    try std.testing.expectEqual(@as(usize, 4096), context.response.body.len);
}

test "compress middleware negotiates deflate when preferred" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip;q=0.5, deflate;q=1",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "deflate",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(context.response.body.len < 4096);
    try std.testing.expectEqual(@as(u8, 0x78), context.response.body[0]);
}

test "compress middleware returns 406 when identity is refused" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "identity;q=0",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 406), context.response.status);
    try std.testing.expectEqualStrings("Not Acceptable", context.response.body);
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
}

test "compress middleware honors no-transform" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.setHeader("Cache-Control", "no-transform");
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
    try std.testing.expectEqual(@as(usize, 4096), context.response.body.len);
}
