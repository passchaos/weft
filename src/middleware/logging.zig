const std = @import("std");
const ctx_mod = @import("../ctx.zig");

/// Log method, target, status, and elapsed wall time after the chain finishes.
pub fn log(ctx: *ctx_mod.Ctx) anyerror!void {
    const started = std.Io.Timestamp.now(ctx.io, .awake);
    defer {
        const elapsed = started.untilNow(ctx.io, .awake);
        std.log.scoped(.weft).info(
            "{s} {s} -> {d} ({d} ns)",
            .{
                ctx.method().string(),
                ctx.target(),
                ctx.response.status,
                elapsed.nanoseconds,
            },
        );
    }
    try ctx.next();
}
