const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const request_id = @import("request_id.zig");

/// Log method, target, protocol, remote address, request id, status, and
/// elapsed wall time after the chain finishes. Server errors use the warning
/// level.
pub fn log(ctx: *ctx_mod.Ctx) anyerror!void {
    const started = std.Io.Timestamp.now(ctx.io, .awake);
    defer {
        const elapsed = started.untilNow(ctx.io, .awake);
        const id = request_id.from(ctx) orelse "-";
        const protocol = @tagName(ctx.protocol());
        const remote = if (ctx.clientAddress()) |address|
            std.fmt.allocPrint(ctx.arena, "{f}", .{address}) catch "-"
        else
            "-";

        if (ctx.response.status >= 500) {
            std.log.scoped(.weft).warn(
                "{s} {s} proto={s} remote={s} id={s} -> {d} ({d} ns)",
                .{
                    ctx.method().string(),
                    ctx.target(),
                    protocol,
                    remote,
                    id,
                    ctx.response.status,
                    elapsed.nanoseconds,
                },
            );
        } else {
            std.log.scoped(.weft).info(
                "{s} {s} proto={s} remote={s} id={s} -> {d} ({d} ns)",
                .{
                    ctx.method().string(),
                    ctx.target(),
                    protocol,
                    remote,
                    id,
                    ctx.response.status,
                    elapsed.nanoseconds,
                },
            );
        }
    }
    try ctx.next();
}
