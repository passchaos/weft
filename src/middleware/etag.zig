const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const precondition = @import("../precondition.zig");

/// Add a content-derived `ETag` to buffered responses and answer
/// `If-None-Match` with `304`.
///
/// Register this middleware outside `Compress` so the tag covers the final
/// representation bytes (including `Content-Encoding`) and `Vary` is already
/// present.
pub const Etag = struct {
    /// Emit a weak validator by default; weak tags still satisfy
    /// `If-None-Match` for `GET`/`HEAD`.
    weak: bool = true,

    pub fn handler(self: *Etag) ctx_mod.Handler {
        return ctx_mod.withContext(Etag, self, call);
    }

    fn call(self: *Etag, ctx: *ctx_mod.Ctx) anyerror!void {
        try ctx.next();

        if (ctx.response.stream != null or
            ctx.response.upgrade != null or
            ctx.response.body.len == 0 or
            ctx.response.status != 200 or
            ctx.response.header("etag") != null)
        {
            return;
        }

        const hash = std.hash.Wyhash.hash(0, ctx.response.body);
        var strong_buffer: [32]u8 = undefined;
        const strong = std.fmt.bufPrint(
            &strong_buffer,
            "\"{x}\"",
            .{hash},
        ) catch return;
        var weak_buffer: [34]u8 = undefined;
        const value = if (self.weak)
            std.fmt.bufPrint(&weak_buffer, "W/{s}", .{strong}) catch return
        else
            strong;
        try ctx.setHeader("ETag", value);

        // RFC 9110 §13.1.2 only defines the 304 short-circuit for GET and
        // HEAD. The handler has already run for other methods, so turning
        // their response into 304 would both misstate the result and hide the
        // representation the client asked for.
        if (ctx.method() != .GET and ctx.method() != .HEAD) return;

        const if_none_match = ctx.header("if-none-match") orelse return;
        const matches = if (self.weak)
            precondition.weakMatches(if_none_match, strong)
        else
            precondition.strongMatches(if_none_match, strong);
        if (!matches) return;

        ctx.response.clearBody();
        ctx.setStatus(304);
    }
};

test "etag middleware answers If-None-Match with 304" {
    const allocator = std.testing.allocator;

    var etag = Etag{};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var first = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{etag.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("hello");
            }
        }.handle),
    };
    try first.run();
    try std.testing.expectEqual(@as(u16, 200), first.response.status);
    const tag = first.response.header("etag").?;
    try std.testing.expect(tag.len > 0);

    var headers = [_]@import("netz").http1.Header{.{
        .name = "If-None-Match",
        .value = tag,
    }};
    var conditional_request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var second_arena = std.heap.ArenaAllocator.init(allocator);
    defer second_arena.deinit();
    var second = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = second_arena.allocator(),
        .limits = .{},
        .request = &conditional_request,
        .response = ctx_mod.Response.init(second_arena.allocator(), 1024),
        .middleware = &.{etag.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("hello");
            }
        }.handle),
    };
    try second.run();
    try std.testing.expectEqual(@as(u16, 304), second.response.status);
    try std.testing.expectEqualStrings("", second.response.body);
    try std.testing.expectEqualStrings(tag, second.response.header("etag").?);
}

test "etag middleware keeps non-GET responses intact" {
    const allocator = std.testing.allocator;
    const hash = std.hash.Wyhash.hash(0, "hello");
    const tag = try std.fmt.allocPrint(allocator, "W/\"{x}\"", .{hash});
    defer allocator.free(tag);

    var headers = [_]@import("netz").http1.Header{.{
        .name = "If-None-Match",
        .value = tag,
    }};
    var request: @import("netz").http1.Request = .{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var etag = Etag{};
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{etag.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("hello");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 200), context.response.status);
    try std.testing.expectEqualStrings("hello", context.response.body);
    try std.testing.expect(context.response.header("etag") != null);
}
