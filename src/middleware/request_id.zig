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
    var generated: [32]u8 = undefined;
    const id = if (incoming) |value|
        if (valid(value)) value else try generate(ctx, &generated)
    else
        try generate(ctx, &generated);

    try ctx.setHeader("X-Request-Id", id);
    // The response owns the copied value; storing that slice keeps the local
    // and the header coherent without a second allocation.
    try ctx.set(RequestId, .{
        .value = ctx.responseHeader("x-request-id").?,
    });
    try ctx.next();
}

/// Read the id established by `requestId` middleware, if present.
pub fn from(ctx: *ctx_mod.Ctx) ?[]const u8 {
    const id = ctx.get(RequestId) orelse return null;
    return id.value;
}

/// Per-thread PRNG. Seeding is the only secure-random syscall; ids themselves
/// only need to be unique, so a fast PRNG keeps the hot path allocation- and
/// syscall-free.
threadlocal var generator: ?std.Random.DefaultPrng = null;

fn generate(ctx: *ctx_mod.Ctx, buffer: *[32]u8) ![]const u8 {
    if (generator == null) {
        var seed: [8]u8 = undefined;
        try std.Io.randomSecure(ctx.io, &seed);
        generator = std.Random.DefaultPrng.init(
            std.mem.readInt(u64, &seed, .little),
        );
    }
    var bytes: [16]u8 = undefined;
    generator.?.random().bytes(&bytes);
    buffer.* = std.fmt.bytesToHex(bytes, .lower);
    return buffer;
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

test "request id middleware stores the response copy" {
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{ctx_mod.handler(requestId)},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };

    try context.run();
    const header = context.response.header("x-request-id").?;
    const local = from(&context).?;
    try std.testing.expectEqualStrings(header, local);
    try std.testing.expect(local.ptr == header.ptr);
}
