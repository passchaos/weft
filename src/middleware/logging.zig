const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const request_id = @import("request_id.zig");

/// Log method, target, request id, status, and elapsed wall time after the
/// chain finishes. Server errors use the warning level.
pub fn log(ctx: *ctx_mod.Ctx) anyerror!void {
    const started = std.Io.Timestamp.now(ctx.io, .awake);
    defer {
        const elapsed = started.untilNow(ctx.io, .awake);
        const id = request_id.from(ctx) orelse "-";
        if (ctx.response.status >= 500) {
            std.log.scoped(.weft).warn(
                "{s} {s} id={s} -> {d} ({d} ns)",
                .{
                    ctx.method().string(),
                    ctx.target(),
                    id,
                    ctx.response.status,
                    elapsed.nanoseconds,
                },
            );
        } else {
            std.log.scoped(.weft).info(
                "{s} {s} id={s} -> {d} ({d} ns)",
                .{
                    ctx.method().string(),
                    ctx.target(),
                    id,
                    ctx.response.status,
                    elapsed.nanoseconds,
                },
            );
        }
    }
    try ctx.next();
}
