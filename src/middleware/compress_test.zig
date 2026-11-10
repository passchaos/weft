const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const response_mod = @import("../response.zig");
const stream_mod = @import("../stream.zig");
const compress_mod = @import("compress.zig");
const negotiate = @import("compress/negotiate.zig");

const Compress = compress_mod.Compress;
const compress = compress_mod.compress;
const quality = negotiate.quality;
const containsToken = negotiate.containsToken;

test "compress quality parsing accepts OWS and rejects invalid values" {
    try std.testing.expectEqual(@as(?u16, 500), quality("q=0.5"));
    try std.testing.expectEqual(@as(?u16, 500), quality(" q = 0.5 "));
    try std.testing.expectEqual(@as(?u16, 0), quality("q=2"));
    try std.testing.expectEqual(@as(?u16, 0), quality("q=abc"));
    try std.testing.expectEqual(@as(?u16, 0), quality("q=-1"));
    try std.testing.expect(quality("foo=bar") == null);
    try std.testing.expect(quality("") == null);
}

test "compress middleware gzips an accepted response" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip, deflate",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var gzip_middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{gzip_middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "gzip",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(context.response.body.len < 4096);
    try std.testing.expectEqual(@as(u8, 0x1f), context.response.body[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), context.response.body[1]);
    try std.testing.expect(
        containsToken(context.response.header("vary").?, "accept-encoding"),
    );
}

test "compress middleware honors q=0 and small bodies" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip;q=0, identity",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var gzip_middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{gzip_middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
    try std.testing.expectEqual(@as(usize, 4096), context.response.body.len);
    // A client accepting gzip would still get a compressed representation.
    try std.testing.expect(context.response.header("vary") != null);
}

test "compress middleware omits Vary for bodies that never compress" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("tiny");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
    // Every Accept-Encoding value receives the same identity response, so the
    // field would not affect caching.
    try std.testing.expect(context.response.header("vary") == null);
}

test "compress middleware negotiates deflate when preferred" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip;q=0.5, deflate;q=1",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "deflate",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(context.response.body.len < 4096);
    try std.testing.expectEqual(@as(u8, 0x78), context.response.body[0]);
}

test "compress middleware returns 406 when identity is refused" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "identity;q=0",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 406), context.response.status);
    try std.testing.expectEqualStrings("Not Acceptable", context.response.body);
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
}

test "compress middleware returns 406 for streamed bodies when identity is refused" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Producer = struct {
        var cancelled: bool = false;

        fn run(_: ?*anyopaque, _: *stream_mod.Writer) anyerror!void {}

        fn cancel(_: ?*anyopaque) void {
            cancelled = true;
        }
    };

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "identity;q=0",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.stream(.{
                    .write_fn = Producer.run,
                    .cancel_fn = Producer.cancel,
                    .length = 16,
                });
            }
        }.handle),
    };

    Producer.cancelled = false;
    try context.run();
    try std.testing.expect(Producer.cancelled);
    try std.testing.expectEqual(@as(u16, 406), context.response.status);
    try std.testing.expectEqualStrings("Not Acceptable", context.response.body);
    try std.testing.expect(context.response.stream == null);
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
}

fn decodeBody(
    allocator: std.mem.Allocator,
    encoding: []const u8,
    body: []const u8,
    max_output_len: usize,
) ![]const u8 {
    const headers = [_]@import("netz").http1.Header{.{
        .name = "Content-Encoding",
        .value = encoding,
    }};
    const decoded = try @import("netz").http1.content_coding.decodeHeadersAlloc(
        allocator,
        &headers,
        body,
        max_output_len,
    );
    return decoded.bytes;
}

fn expectRoundTrip(
    encoding: []const u8,
    compressed: []const u8,
    original: []const u8,
) !void {
    const decoded = try decodeBody(
        std.testing.allocator,
        encoding,
        compressed,
        original.len,
    );
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(original, decoded);
}

test "compress middleware supports brotli" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "br",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "br",
        context.response.header("content-encoding").?,
    );
    const original = try allocator.alloc(u8, 4096);
    defer allocator.free(original);
    @memset(original, 'a');
    try expectRoundTrip("br", context.response.body, original);
}

test "compress middleware supports zstd" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "zstd",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "zstd",
        context.response.header("content-encoding").?,
    );
    const original = try allocator.alloc(u8, 4096);
    defer allocator.free(original);
    @memset(original, 'a');
    try expectRoundTrip("zstd", context.response.body, original);
}

test "compress middleware wraps streamed bodies with gzip" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Producer = struct {
        var chunk: []const u8 = &.{};

        fn run(_: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
            try writer.write(chunk);
            try writer.write(chunk);
        }
    };

    const Collector = struct {
        allocator: std.mem.Allocator,
        bytes: std.ArrayListUnmanaged(u8) = .empty,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(self.allocator, data);
        }
    };

    const chunk = try allocator.alloc(u8, 2048);
    defer allocator.free(chunk);
    @memset(chunk, 'a');
    Producer.chunk = chunk;

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.setHeader("Content-Length", "4096");
                try ctx.stream(.{
                    .write_fn = Producer.run,
                    .length = 4096,
                });
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "gzip",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(
        context.response.header("content-length") == null,
    );

    var collector = Collector{ .allocator = arena.allocator() };
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };
    if (context.response.stream) |*body| {
        try body.run(&writer);
    } else return error.TestUnexpectedResult;

    const decode_headers = [_]@import("netz").http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    const decoded = try @import("netz").http1.content_coding.decodeHeadersAlloc(
        arena.allocator(),
        &decode_headers,
        collector.bytes.items,
        4096,
    );
    try std.testing.expectEqual(@as(usize, 4096), decoded.bytes.len);
    for (decoded.bytes) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
}

fn expectStreamCoding(
    allocator: std.mem.Allocator,
    coding: []const u8,
    accept: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Producer = struct {
        var chunk: []const u8 = &.{};

        fn run(_: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
            try writer.write(chunk);
            try writer.write(chunk);
        }
    };

    const Collector = struct {
        allocator: std.mem.Allocator,
        bytes: std.ArrayListUnmanaged(u8) = .empty,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(self.allocator, data);
        }
    };

    const chunk = try allocator.alloc(u8, 2048);
    defer allocator.free(chunk);
    @memset(chunk, 'a');
    Producer.chunk = chunk;

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = accept,
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.setHeader("Content-Length", "4096");
                try ctx.stream(.{
                    .context = null,
                    .write_fn = Producer.run,
                    .length = 4096,
                });
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        coding,
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(
        context.response.header("content-length") == null,
    );

    var collector = Collector{ .allocator = arena.allocator() };
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };
    if (context.response.stream) |*body| {
        try body.run(&writer);
    } else return error.TestUnexpectedResult;

    const decode_headers = [_]@import("netz").http1.Header{.{
        .name = "Content-Encoding",
        .value = coding,
    }};
    const decoded = try @import("netz").http1.content_coding.decodeHeadersAlloc(
        arena.allocator(),
        &decode_headers,
        collector.bytes.items,
        4096,
    );
    try std.testing.expectEqual(@as(usize, 4096), decoded.bytes.len);
    for (decoded.bytes) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
}

test "compress middleware bounds one streamed chunk" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Producer = struct {
        fn run(_: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
            try writer.write("0123456789abcdef");
        }
    };
    const Collector = struct {
        bytes: std.ArrayListUnmanaged(u8) = .empty,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(allocator, data);
        }
    };

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{ .max_response_bytes = 8 },
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.stream(.{ .write_fn = Producer.run });
            }
        }.handle),
    };

    try context.run();
    var collector = Collector{};
    defer collector.bytes.deinit(allocator);
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };
    try std.testing.expectError(
        error.ResponseTooLarge,
        context.response.stream.?.run(&writer),
    );
    try std.testing.expectEqual(@as(usize, 0), collector.bytes.items.len);
}

test "compress middleware wraps streamed bodies with deflate" {
    try expectStreamCoding(std.testing.allocator, "deflate", "deflate");
}

test "compress middleware wraps streamed bodies with brotli" {
    try expectStreamCoding(std.testing.allocator, "br", "br");
}

test "compress middleware wraps streamed bodies with zstd" {
    try expectStreamCoding(std.testing.allocator, "zstd", "zstd");
}

test "compress middleware honors no-transform" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.setHeader("Cache-Control", "no-transform");
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
    try std.testing.expectEqual(@as(usize, 4096), context.response.body.len);
}

test "compress middleware streams gzip within a small arena" {
    const allocator = std.testing.allocator;
    var arena_buffer: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    const arena = fixed.allocator();

    const Producer = struct {
        fn run(_: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
            var chunk: [1024]u8 = undefined;
            @memset(&chunk, 'a');
            var index: usize = 0;
            while (index < 256) : (index += 1) try writer.write(&chunk);
        }
    };

    const Collector = struct {
        bytes: std.ArrayListUnmanaged(u8) = .empty,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(allocator, data);
        }
    };

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena,
        .limits = .{ .max_response_bytes = 512 * 1024 },
        .request = &request,
        .response = response_mod.Response.init(arena, 512 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.stream(.{ .write_fn = Producer.run });
            }
        }.handle),
    };

    try context.run();
    var collector = Collector{};
    defer collector.bytes.deinit(allocator);
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };
    try context.response.stream.?.run(&writer);

    const decode_headers = [_]@import("netz").http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    const decoded = try @import("netz").http1.content_coding.decodeHeadersAlloc(
        allocator,
        &decode_headers,
        collector.bytes.items,
        256 * 1024,
    );
    defer allocator.free(decoded.bytes);
    try std.testing.expectEqual(@as(usize, 256 * 1024), decoded.bytes.len);
    for (decoded.bytes) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
}

test "compress middleware stages buffered growth outside a small arena" {
    const allocator = std.testing.allocator;
    var arena_buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    const arena = fixed.allocator();

    // Incompressible input keeps the compressed output near the input size.
    var body: [3000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    prng.random().bytes(&body);

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena,
        .request_allocator = allocator,
        .limits = .{ .max_response_bytes = 8192 },
        .request = &request,
        .response = response_mod.Response.init(arena, 8192),
        .middleware = &.{middleware.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };
    try context.response.setHeader("Content-Type", "text/plain");
    try context.response.setBody(&body);

    try context.run();
    try std.testing.expectEqualStrings(
        "gzip",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(context.response.body.len > 0);
}
