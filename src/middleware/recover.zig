const std = @import("std");
const logging_mod = @import("../logging.zig");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const errors_mod = @import("../errors.zig");
const response_mod = @import("../response.zig");

/// Convert an uncommitted handler failure into a 500 response.
///
/// If a handler already committed a status or header before failing, the
/// partial response is preserved and marked `Connection: close` so a client
/// cannot reuse a connection whose framing may be incomplete.
pub fn recover(ctx: *ctx_mod.Ctx) anyerror!void {
    ctx.next() catch |err| {
        if (err == error.Canceled) return error.Canceled;

        logging_mod.logWarn(
            "weft",
            "recovered handler failure: {s}",
            .{@errorName(err)},
            .{ .err = @errorName(err) },
        );
        if (!ctx.response.committed) {
            const status = errors_mod.statusForHandlerError(err);
            ctx.response.reset();
            ctx.setStatus(status);
            ctx.text(response_mod.reasonFor(status)) catch {};
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
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{handler_mod.handler(recover)},
        .final_handler = handler_mod.handler(struct {
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

test "recover preserves dispatch statuses for client errors" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var request: @import("netz").http1.Request = .{
        .method = .POST,
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
        .middleware = &.{handler_mod.handler(recover)},
        .final_handler = handler_mod.handler(struct {
            fn handle(_: *ctx_mod.Ctx) anyerror!void {
                return error.InvalidJson;
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 400), context.response.status);
    try std.testing.expectEqualStrings("Bad Request", context.response.body);
}
