const std = @import("std");
const ctx_mod = @import("../ctx.zig");

/// Preserve an incoming `X-Request-Id`, or generate a 128-bit hex id.
pub fn requestId(ctx: *ctx_mod.Ctx) anyerror!void {
    if (ctx.header("x-request-id") == null) {
        var bytes: [16]u8 = undefined;
        try std.Io.randomSecure(ctx.io, &bytes);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        try ctx.setHeader(
            "X-Request-Id",
            try ctx.arena.dupe(u8, &hex),
        );
    }
    try ctx.next();
}
