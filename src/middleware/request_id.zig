const std = @import("std");
const ctx_mod = @import("../ctx.zig");

/// Maximum accepted or generated request-id length.
pub const max_length = 128;

pub const RequestId = struct {
    value: []const u8,
};

/// Preserve a valid incoming `X-Request-Id` or generate a 128-bit hex id, then
/// expose the same value to downstream middleware and the response.
pub fn requestId(ctx: *ctx_mod.Ctx) anyerror!void {
    const incoming = ctx.header("x-request-id");
    const id = if (incoming) |value|
        if (valid(value)) value else try generate(ctx)
    else
        try generate(ctx);

    try ctx.set(RequestId, .{ .value = id });
    try ctx.setHeader("X-Request-Id", id);
    try ctx.next();
}

/// Read the id established by `requestId` middleware, if present.
pub fn from(ctx: *ctx_mod.Ctx) ?[]const u8 {
    const id = ctx.get(RequestId) orelse return null;
    return id.value;
}

fn generate(ctx: *ctx_mod.Ctx) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try std.Io.randomSecure(ctx.io, &bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return ctx.arena.dupe(u8, &hex);
}

fn valid(value: []const u8) bool {
    if (value.len == 0 or value.len > max_length) return false;
    for (value) |char| {
        switch (char) {
            'a'...'z', 'A'...'Z', '0'...'9' => {},
            '-', '_', '.', ':', '/' => {},
            else => return false,
        }
    }
    return true;
}

test "request id accepts safe incoming values and rejects unsafe ones" {
    try std.testing.expect(valid("abc-123_DEF.42:9/1"));
    try std.testing.expect(!valid(""));
    try std.testing.expect(!valid("bad value"));
    try std.testing.expect(!valid("a\r\nb"));
}
