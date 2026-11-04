const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const errors_mod = @import("../errors.zig");
const request_id = @import("request_id.zig");

/// Status used for an access-log entry when the client canceled the request.
pub const client_closed_status = 499;

/// Access-log encoding. `json` emits one compact object per request as the
/// log message; the standard logger still prefixes its level and scope.
pub const Format = enum { text, json };

/// Configurable access logger. `log` remains the plain-text shorthand.
pub const Log = struct {
    format: Format = .text,

    pub fn handler(self: *Log) ctx_mod.Handler {
        return ctx_mod.withContext(Log, self, call);
    }

    fn call(self: *Log, ctx: *ctx_mod.Ctx) anyerror!void {
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

            switch (self.format) {
                .text => emitText(ctx, protocol, remote, id, status, elapsed),
                .json => emitJson(ctx, protocol, remote, id, status, elapsed),
            }
        }
        ctx.next() catch |err| {
            failure = err;
            return err;
        };
    }
};

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
        emitText(ctx, protocol, remote, id, status, elapsed);
    }
    ctx.next() catch |err| {
        failure = err;
        return err;
    };
}

fn emitText(
    ctx: *ctx_mod.Ctx,
    protocol: []const u8,
    remote: []const u8,
    id: []const u8,
    status: u16,
    elapsed: std.Io.Duration,
) void {
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

fn emitJson(
    ctx: *ctx_mod.Ctx,
    protocol: []const u8,
    remote: []const u8,
    id: []const u8,
    status: u16,
    elapsed: std.Io.Duration,
) void {
    const allocator = ctx.arena;
    const method = jsonEscape(allocator, ctx.method().string()) catch return;
    const target = jsonEscape(allocator, ctx.target()) catch return;
    const remote_value = jsonEscape(allocator, remote) catch return;
    const id_value = jsonEscape(allocator, id) catch return;
    const line = std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"{s}\",\"target\":\"{s}\",\"proto\":\"{s}\"," ++
            "\"remote\":\"{s}\",\"id\":\"{s}\",\"status\":{d}," ++
            "\"duration_ns\":{d}}}",
        .{
            method,
            target,
            protocol,
            remote_value,
            id_value,
            status,
            elapsed.nanoseconds,
        },
    ) catch return;
    if (status >= 500) {
        std.log.scoped(.weft).warn("{s}", .{line});
    } else {
        std.log.scoped(.weft).info("{s}", .{line});
    }
}

/// Escape one value for a JSON string literal using `allocator`.
fn jsonEscape(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8).empty;
    errdefer output.deinit(allocator);
    for (value) |byte| {
        switch (byte) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            0...8, 11, 12, 14...0x1f, 0x7f => {
                const hex = "0123456789abcdef";
                try output.appendSlice(allocator, "\\u00");
                try output.append(allocator, hex[byte >> 4]);
                try output.append(allocator, hex[byte & 0x0f]);
            },
            else => try output.append(allocator, byte),
        }
    }
    return output.toOwnedSlice(allocator);
}

fn resolveStatus(response_status: u16, failure: ?anyerror) u16 {
    const err = failure orelse return response_status;
    if (err == error.Canceled) return client_closed_status;
    return errors_mod.statusForHandlerError(err);
}

test "json access log escapes control characters and quotes" {
    const allocator = std.testing.allocator;
    const escaped = try jsonEscape(allocator, "a\"b\\c\n\x01");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings(
        "a\\\"b\\\\c\\n\\u0001",
        escaped,
    );
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
