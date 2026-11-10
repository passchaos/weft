//! Structured logging for weft through kron.
//!
//! `AccessLog` emits one typed event per request. Internal server diagnostics
//! use the process-wide kron logger when the application installs one and fall
//! back to `std.log` otherwise, so weft remains usable without a logging
//! runtime.
const std = @import("std");
const kron = @import("kron");
const ctx_mod = @import("ctx.zig");
const errors_mod = @import("errors.zig");
const request_id = @import("middleware/request_id.zig");
const target_mod = @import("target.zig");

pub const Level = kron.Level;
pub const Field = kron.Field;
pub const kv = kron.kv;
pub const array = kron.array;
pub const group = kron.group;
pub const durationNs = kron.durationNs;

pub const client_closed_status = 499;

/// Emit a diagnostic through kron's process-wide owner when one is installed.
/// The formatted message is preserved, and `fields` carries typed values for
/// structured sinks. Without a kron owner the call falls back to `std.log`.
pub fn logf(
    level: Level,
    scope: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    fields: anytype,
) void {
    if (kron.global.getLogging() != null) {
        kron.global.logf(level, scope, fmt, args, fields);
        return;
    }
    const std_level: std.log.Level = switch (level) {
        .err, .fatal => .err,
        .warn => .warn,
        .info => .info,
        .debug, .trace => .debug,
        .off => return,
    };
    switch (std_level) {
        .err => std.log.scoped(.weft).err(fmt, args),
        .warn => std.log.scoped(.weft).warn(fmt, args),
        .info => std.log.scoped(.weft).info(fmt, args),
        .debug => std.log.scoped(.weft).debug(fmt, args),
    }
}

pub fn logWarn(scope: []const u8, comptime fmt: []const u8, args: anytype, fields: anytype) void {
    logf(.warn, scope, fmt, args, fields);
}

pub fn logErr(scope: []const u8, comptime fmt: []const u8, args: anytype, fields: anytype) void {
    logf(.err, scope, fmt, args, fields);
}

pub fn logInfo(scope: []const u8, comptime fmt: []const u8, args: anytype, fields: anytype) void {
    logf(.info, scope, fmt, args, fields);
}

pub fn logDebug(scope: []const u8, comptime fmt: []const u8, args: anytype, fields: anytype) void {
    logf(.debug, scope, fmt, args, fields);
}

/// Structured access log. Emits one kron event per request with the fields
/// weft already collects for its text and JSON access logs.
pub const AccessLog = struct {
    logging: *kron.Logging,
    scope: []const u8 = "weft.http",
    level: Level = .info,
    message: []const u8 = "request completed",

    pub fn handler(self: *AccessLog) ctx_mod.Handler {
        return ctx_mod.withContext(AccessLog, self, call);
    }

    fn call(self: *AccessLog, ctx: *ctx_mod.Ctx) anyerror!void {
        const started = std.Io.Timestamp.now(ctx.io, .awake);
        var failure: ?anyerror = null;
        defer {
            const elapsed = started.untilNow(ctx.io, .awake);
            const id = request_id.from(ctx) orelse "-";
            var remote_buffer: [64]u8 = undefined;
            const remote = if (ctx.clientAddress()) |address|
                std.fmt.bufPrint(&remote_buffer, "{f}", .{address}) catch "-"
            else
                "-";
            const status = resolveStatus(ctx.response.status, failure);
            const split = target_mod.split(ctx.target());
            const duration_ns: i64 = @intCast(@max(
                elapsed.nanoseconds,
                0,
            ));
            var logger = self.logging.scoped(self.scope);
            _ = logger.tryEmit(self.level, self.message, .{
                .request_id = id,
                .method = ctx.method().string(),
                .path = split.path,
                .query = split.query,
                .status = status,
                .duration_ns = kron.durationNs(duration_ns),
                .protocol = @tagName(ctx.protocol()),
                .remote = remote,
                .err = if (failure) |failure_err| @errorName(failure_err) else "",
            }) catch {};
        }
        ctx.next() catch |err| {
            failure = err;
            return err;
        };
    }
};

pub fn resolveStatus(response_status: u16, failure: ?anyerror) u16 {
    const err = failure orelse return response_status;
    if (err == error.Canceled) return client_closed_status;
    return errors_mod.statusForHandlerError(err);
}

test "structured access log emits typed kron fields" {
    const allocator = std.testing.allocator;
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const logging = try kron.Logging.create(allocator, std.testing.io, .{
        .outputs = &.{.{
            .name = "test",
            .target = .{ .writer = &writer },
            .mode = .sync,
            .format = .json,
            .filter = "debug",
        }},
    });
    defer logging.destroy();

    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = std.testing.allocator,
        .limits = .{},
        .request = &.{
            .method = .GET,
            .target = "/items/42?q=books",
            .version = .http_1_1,
            .headers = &.{},
            .body = "",
            .consumed = 0,
        },
        .response = ctx_mod.Response.init(allocator, 1024),
        .final_handler = ctx_mod.handler(struct {
            fn handle(c: *ctx_mod.Ctx) anyerror!void {
                c.response.setStatus(201);
                try c.text("created");
            }
        }.handle),
        .next_allowed = true,
    };
    defer context.response.deinit();

    var access = AccessLog{ .logging = logging };
    try access.call(&context);

    const line = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, line, "\"request_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"method\":\"GET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"path\":\"/items/42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"query\":\"q=books\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"status\":201") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"duration_ns\"") != null);
}
