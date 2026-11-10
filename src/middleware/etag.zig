const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const response_mod = @import("../response.zig");
const precondition = @import("../precondition.zig");
const stream_mod = @import("../stream.zig");

/// Add a content-derived `ETag` to buffered responses and answer
/// `If-None-Match` with `304`.
///
/// Register this middleware outside `Compress` so the tag covers the final
/// representation bytes (including `Content-Encoding`) and `Vary` is already
/// present.
pub const Etag = struct {
    /// Emit a weak validator by default; weak tags still satisfy
    /// `If-None-Match` for `GET`/`HEAD`.
    weak: bool = true,
    /// Buffer a streamed response up to this many bytes to compute a
    /// content-derived ETag. Zero disables streamed ETags. Buffering only
    /// happens when the producer declares a known length within the cap.
    max_stream_bytes: usize = 0,

    pub fn handler(self: *Etag) handler_mod.Handler {
        return handler_mod.withContext(Etag, self, call);
    }

    fn call(self: *Etag, ctx: *ctx_mod.Ctx) anyerror!void {
        try ctx.next();

        if (ctx.response.upgrade != null or
            ctx.response.status != 200 or
            ctx.response.header("etag") != null)
        {
            return;
        }
        if (ctx.response.stream != null) {
            if (!try self.bufferStream(ctx)) return;
        }
        if (ctx.response.body.len == 0) return;

        const hash = std.hash.Wyhash.hash(0, ctx.response.body);
        var strong_buffer: [32]u8 = undefined;
        const strong = std.fmt.bufPrint(
            &strong_buffer,
            "\"{x}\"",
            .{hash},
        ) catch return;
        var weak_buffer: [34]u8 = undefined;
        const value = if (self.weak)
            std.fmt.bufPrint(&weak_buffer, "W/{s}", .{strong}) catch return
        else
            strong;
        try ctx.setHeader("ETag", value);

        // RFC 9110 §13.1.2 only defines the 304 short-circuit for GET and
        // HEAD. The handler has already run for other methods, so turning
        // their response into 304 would both misstate the result and hide the
        // representation the client asked for.
        if (ctx.method() != .GET and ctx.method() != .HEAD) return;

        const if_none_match = ctx.header("if-none-match") orelse return;
        const matches = if (self.weak)
            precondition.weakMatches(if_none_match, strong)
        else
            precondition.strongMatches(if_none_match, strong);
        if (!matches) return;

        ctx.response.clearBody();
        ctx.setStatus(304);
    }

    fn bufferStream(self: *Etag, ctx: *ctx_mod.Ctx) !bool {
        if (self.max_stream_bytes == 0) return false;
        const body = ctx.response.stream orelse return false;
        const length = body.length orelse return false;
        if (length == 0 or length > self.max_stream_bytes) return false;
        const content_type = ctx.response.header("content-type") orelse "";
        if (std.ascii.startsWithIgnoreCase(content_type, "text/event-stream")) {
            return false;
        }

        var buffer = BoundedBuffer{
            .output = try std.Io.Writer.Allocating.initCapacity(
                ctx.arena,
                @min(length, 4096),
            ),
            .max_bytes = length,
        };
        defer buffer.output.deinit();
        var writer = stream_mod.Writer{
            .context = &buffer,
            .write_fn = BoundedBuffer.write,
        };
        try body.run(&writer);

        const bytes = try ctx.arena.dupe(u8, buffer.output.writer.buffered());
        ctx.response.stream = null;
        try ctx.response.setBody(bytes);
        return true;
    }
};

const BoundedBuffer = struct {
    output: std.Io.Writer.Allocating,
    max_bytes: usize,

    fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
        const self: *BoundedBuffer = @ptrCast(@alignCast(raw orelse
            return error.InvalidWriterState));
        if (data.len > self.max_bytes - self.output.writer.end) {
            return error.ResponseTooLarge;
        }
        try self.output.writer.writeAll(data);
    }
};

test "etag middleware answers If-None-Match with 304" {
    const allocator = std.testing.allocator;

    var etag = Etag{};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var first = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{etag.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("hello");
            }
        }.handle),
    };
    try first.run();
    try std.testing.expectEqual(@as(u16, 200), first.response.status);
    const tag = first.response.header("etag").?;
    try std.testing.expect(tag.len > 0);

    var headers = [_]@import("netz").http1.Header{.{
        .name = "If-None-Match",
        .value = tag,
    }};
    var conditional_request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var second_arena = std.heap.ArenaAllocator.init(allocator);
    defer second_arena.deinit();
    var second = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = second_arena.allocator(),
        .limits = .{},
        .request = &conditional_request,
        .response = response_mod.Response.init(second_arena.allocator(), 1024),
        .middleware = &.{etag.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("hello");
            }
        }.handle),
    };
    try second.run();
    try std.testing.expectEqual(@as(u16, 304), second.response.status);
    try std.testing.expectEqualStrings("", second.response.body);
    try std.testing.expectEqualStrings(tag, second.response.header("etag").?);
}

test "etag middleware keeps non-GET responses intact" {
    const allocator = std.testing.allocator;
    const hash = std.hash.Wyhash.hash(0, "hello");
    const tag = try std.fmt.allocPrint(allocator, "W/\"{x}\"", .{hash});
    defer allocator.free(tag);

    var headers = [_]@import("netz").http1.Header{.{
        .name = "If-None-Match",
        .value = tag,
    }};
    var request: @import("netz").http1.Request = .{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var etag = Etag{};
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{etag.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("hello");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 200), context.response.status);
    try std.testing.expectEqualStrings("hello", context.response.body);
    try std.testing.expect(context.response.header("etag") != null);
}

test "etag middleware hashes bounded streamed responses" {
    const allocator = std.testing.allocator;
    var etag = Etag{ .max_stream_bytes = 1024 };
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{etag.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.stream(.{ .write_fn = producer, .length = 5 });
            }

            fn producer(
                _: ?*anyopaque,
                writer: *stream_mod.Writer,
            ) anyerror!void {
                try writer.write("hello");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(context.response.stream == null);
    try std.testing.expectEqualStrings("hello", context.response.body);
    try std.testing.expect(context.response.header("etag") != null);
}

test "etag middleware leaves unbounded streams streaming" {
    const allocator = std.testing.allocator;
    var etag = Etag{ .max_stream_bytes = 1024 };
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{etag.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.stream(.{ .write_fn = producer });
            }

            fn producer(
                _: ?*anyopaque,
                writer: *stream_mod.Writer,
            ) anyerror!void {
                try writer.write("hello");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(context.response.stream != null);
    try std.testing.expect(context.response.header("etag") == null);
}
