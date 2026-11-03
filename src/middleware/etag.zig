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
        const strong = try std.fmt.allocPrint(
            ctx.arena,
            "\"{x}\"",
            .{hash},
        );
        const value = if (self.weak)
            try std.fmt.allocPrint(ctx.arena, "W/{s}", .{strong})
        else
            strong;
        try ctx.setHeader("ETag", value);

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
