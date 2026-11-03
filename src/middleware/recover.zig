const std = @import("std");
const ctx_mod = @import("../ctx.zig");

/// Convert an uncommitted handler failure into a 500 response.
///
/// If a handler already committed a status or header before failing, the
/// partial response is preserved and marked `Connection: close` so a client
/// cannot reuse a connection whose framing may be incomplete.
pub fn recover(ctx: *ctx_mod.Ctx) anyerror!void {
    ctx.next() catch |err| {
        if (err == error.Canceled) return error.Canceled;

        std.log.scoped(.weft).warn(
            "recovered handler failure: {s}",
            .{@errorName(err)},
        );
        if (!ctx.response.committed) {
            ctx.response.reset();
            ctx.setStatus(500);
            ctx.text("Internal Server Error") catch {};
        } else {
            ctx.setHeader("Connection", "close") catch {};
        }
    };
}

test "recover turns an uncommitted failure into 500" {
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
        .middleware = &.{ctx_mod.handler(recover)},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                _ = ctx;
                return error.Boom;
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 500), context.response.status);
    try std.testing.expectEqualStrings(
        "Internal Server Error",
        context.response.body,
    );
}
