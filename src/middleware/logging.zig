const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const errors_mod = @import("../errors.zig");
const request_id = @import("request_id.zig");

/// Status used for an access-log entry when the client canceled the request.
pub const client_closed_status = 499;

/// Log method, target, protocol, remote address, request id, status, and
/// elapsed wall time after the chain finishes. Handler failures are reported
/// with the status dispatch will emit. Server errors use the warning level.
pub fn log(ctx: *ctx_mod.Ctx) anyerror!void {
    const started = std.Io.Timestamp.now(ctx.io, .awake);
    var failure: ?anyerror = null;
    defer {
        const elapsed = started.untilNow(ctx.io, .awake);
        const id = request_id.from(ctx) orelse "-";
        const protocol = @tagName(ctx.protocol());
        const remote = if (ctx.clientAddress()) |address|
            std.fmt.allocPrint(ctx.arena, "{f}", .{address}) catch "-"
        else
            "-";
        const status = resolveStatus(ctx.response.status, failure);

        if (status >= 500) {
            std.log.scoped(.weft).warn(
                "{s} {s} proto={s} remote={s} id={s} -> {d} ({d} ns)",
                .{
                    ctx.method().string(),
                    ctx.target(),
                    protocol,
                    remote,
                    id,
                    status,
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
                    status,
                    elapsed.nanoseconds,
                },
            );
        }
    }
    ctx.next() catch |err| {
        failure = err;
        return err;
    };
}

fn resolveStatus(response_status: u16, failure: ?anyerror) u16 {
    const err = failure orelse return response_status;
    if (err == error.Canceled) return client_closed_status;
    return errors_mod.statusForHandlerError(err);
}

test "access log status mirrors dispatch and marks cancellation" {
    try std.testing.expectEqual(@as(u16, 200), resolveStatus(200, null));
    try std.testing.expectEqual(@as(u16, 400), resolveStatus(200, error.InvalidJson));
    try std.testing.expectEqual(@as(u16, 415), resolveStatus(
        200,
        error.UnsupportedMediaType,
    ));
    try std.testing.expectEqual(@as(u16, 500), resolveStatus(
        200,
        error.Unexpected,
    ));
    try std.testing.expectEqual(
        client_closed_status,
        resolveStatus(200, error.Canceled),
    );
}
