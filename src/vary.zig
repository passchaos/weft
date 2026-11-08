const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");

/// Append `value` to the response `Vary` field unless it is already present.
/// A response already carrying `Vary: *` covers every request field, so no
/// further token is added.
pub fn add(ctx: *ctx_mod.Ctx, value: []const u8) !void {
    const existing = ctx.responseHeader("vary") orelse {
        return ctx.setHeader("Vary", value);
    };
    if (std.mem.trim(u8, existing, " \t").len == 0) {
        return ctx.setHeader("Vary", value);
    }

    var tokens = std.mem.splitScalar(u8, existing, ',');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t");
        if (std.mem.eql(u8, token, "*") or
            std.ascii.eqlIgnoreCase(token, value))
        {
            return;
        }
    }

    return ctx.setHeader(
        "Vary",
        try std.fmt.allocPrint(ctx.arena, "{s}, {s}", .{ existing, value }),
    );
}

test "vary appends unique tokens and respects the wildcard" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]netz.http1.Header{};
    var request = netz.http1.Request{
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
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try add(&context, "Accept-Encoding");
    try std.testing.expectEqualStrings(
        "Accept-Encoding",
        context.responseHeader("vary").?,
    );

    // The same token is not duplicated, even with different casing.
    try add(&context, "accept-encoding");
    try std.testing.expectEqualStrings(
        "Accept-Encoding",
        context.responseHeader("vary").?,
    );

    try add(&context, "Origin");
    try std.testing.expectEqualStrings(
        "Accept-Encoding, Origin",
        context.responseHeader("vary").?,
    );

    // A wildcard already covers every request field.
    try context.setHeader("Vary", "*");
    try add(&context, "Accept-Encoding");
    try std.testing.expectEqualStrings("*", context.responseHeader("vary").?);

    // An empty field value is replaced instead of producing ", token".
    try context.setHeader("Vary", "");
    try add(&context, "Accept-Encoding");
    try std.testing.expectEqualStrings(
        "Accept-Encoding",
        context.responseHeader("vary").?,
    );
}
