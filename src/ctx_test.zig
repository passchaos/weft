const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const body_mod = @import("body.zig");
const handler_mod = @import("handler.zig");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const query_mod = @import("query.zig");
const cookie_mod = @import("cookie.zig");
const stream_mod = @import("stream.zig");
const sse_mod = @import("sse.zig");

const Ctx = ctx_mod.Ctx;
const BodyReader = body_mod.BodyReader;
const ReplayReader = body_mod.ReplayReader;
const DecodedReader = body_mod.DecodedReader;
const LimitedReader = body_mod.LimitedReader;
const H2StreamReader = body_mod.H2StreamReader;
const H3StreamReader = body_mod.H3StreamReader;
const Handler = handler_mod.Handler;
const Locals = handler_mod.Locals;
const Param = handler_mod.Param;
const Protocol = handler_mod.Protocol;
const ClientInfo = handler_mod.ClientInfo;
const Response = response_mod.Response;
const Header = response_mod.Header;
const Limits = limits_mod.Limits;
const QueryPair = query_mod.Pair;
const SetCookie = cookie_mod.SetCookie;
const StreamBody = stream_mod.Body;
const StreamWriter = stream_mod.Writer;
const SseEvent = sse_mod.Event;
const resolveClientAddress = handler_mod.resolveClientAddress;
const max_params = handler_mod.max_params;
const max_locals = handler_mod.max_locals;
const handlerFor = handler_mod.handlerFor;
const handler = handler_mod.handler;
const withContext = handler_mod.withContext;
const stream_reader_buffer_bytes = body_mod.stream_reader_buffer_bytes;
const isJsonMediaType = ctx_mod.isJsonMediaType;

test "headerValues iterates duplicate request fields" {
    var headers = [_]netz.http1.Header{
        .{ .name = "X-Test", .value = "one" },
        .{ .name = "x-test", .value = "two" },
        .{ .name = "Other", .value = "three" },
    };
    var request = netz.http1.Request{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = Response.init(arena.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    var values = context.headerValues("X-Test");
    try std.testing.expectEqualStrings("one", values.next().?);
    try std.testing.expectEqualStrings("two", values.next().?);
    try std.testing.expect(values.next() == null);
    try std.testing.expectEqual(@as(usize, 3), context.headers().len);
}

test "trailers are exposed by name and as a slice" {
    var trailers = [_]netz.http1.Header{
        .{ .name = "X-Checksum", .value = "abc" },
        .{ .name = "X-Trace", .value = "one" },
    };
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .trailers = &trailers,
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = Response.init(arena.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectEqual(@as(usize, 2), context.trailers().len);
    try std.testing.expectEqualStrings("abc", context.trailer("x-checksum").?);
    try std.testing.expect(context.trailer("missing") == null);
}

test "trailer lookup keeps the bounded reader intact" {
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var replay = ReplayReader{ .body = "abcdef" };
    var limited = LimitedReader{
        .inner = .{ .replay = &replay },
        .remaining = 3,
    };
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .body_reader = .{ .limited = &limited },
        .response = Response.init(arena.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectEqual(@as(usize, 0), context.trailers().len);
    try std.testing.expect(context.body_reader.? == .limited);
    try std.testing.expectError(error.PayloadTooLarge, context.readBody());
}

test "readBody maps arena exhaustion to PayloadTooLarge" {
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var arena_buffer: [8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var replay = ReplayReader{ .body = "0123456789abcdef" };
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .limits = .{
            .max_body_bytes = 64,
            .max_request_arena_bytes = 64,
        },
        .request = &request,
        .body_reader = .{ .replay = &replay },
        .response = Response.init(fixed.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectError(error.PayloadTooLarge, context.readBody());
}

test "readBody releases staging when the arena is too small" {
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var arena_buffer: [8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var replay = ReplayReader{ .body = "0123456789abcdef" };
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        // Staging uses the testing allocator, which reports a leak if the
        // failed arena copy does not release it.
        .request_allocator = std.testing.allocator,
        .limits = .{
            .max_body_bytes = 64,
            .max_request_arena_bytes = 64,
        },
        .request = &request,
        .body_reader = .{ .replay = &replay },
        .response = Response.init(fixed.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectError(error.PayloadTooLarge, context.readBody());
}

test "decodedBody maps arena exhaustion to PayloadTooLarge" {
    const allocator = std.testing.allocator;
    const plain = try allocator.alloc(u8, 3000);
    defer allocator.free(plain);
    @memset(plain, 'a');

    var compressed_output = try std.Io.Writer.Allocating.initCapacity(
        allocator,
        64,
    );
    defer compressed_output.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var encoder = try std.compress.flate.Compress.init(
        &compressed_output.writer,
        &window,
        .gzip,
        .default,
    );
    try encoder.writer.writeAll(plain);
    try encoder.finish();

    var headers = [_]netz.http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var replay = ReplayReader{ .body = compressed_output.written() };
    // The encoded body fits, the decoded output does not, and there is no
    // server staging allocator.
    var arena_buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .limits = .{ .max_body_bytes = 8192, .max_request_arena_bytes = 64 },
        .request = &request,
        .body_reader = .{ .replay = &replay },
        .response = Response.init(fixed.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectError(
        error.PayloadTooLarge,
        context.decodedBody(),
    );
}

test "bodyForm maps arena exhaustion to PayloadTooLarge" {
    var headers = [_]netz.http1.Header{.{
        .name = "Content-Type",
        .value = "application/x-www-form-urlencoded",
    }};
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "a=1&b=2&c=3",
        .consumed = 0,
    };
    var arena_buffer: [16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .limits = .{ .max_body_bytes = 64, .max_request_arena_bytes = 16 },
        .request = &request,
        .response = Response.init(fixed.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectError(error.PayloadTooLarge, context.bodyForm());
}

test "bodyJson maps arena exhaustion to PayloadTooLarge" {
    const Payload = struct { data: []const u8 };
    var headers = [_]netz.http1.Header{.{
        .name = "Content-Type",
        .value = "application/json",
    }};
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "{\"data\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
        .consumed = 0,
    };
    var arena_buffer: [16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .limits = .{ .max_body_bytes = 128, .max_request_arena_bytes = 16 },
        .request = &request,
        .response = Response.init(fixed.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectError(
        error.PayloadTooLarge,
        context.bodyJson(Payload),
    );
}

test "multipart maps arena exhaustion to PayloadTooLarge" {
    var headers = [_]netz.http1.Header{.{
        .name = "Content-Type",
        .value = "multipart/form-data; boundary=weft",
    }};
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "--weft\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n" ++
            "1\r\n--weft--\r\n",
        .consumed = 0,
    };
    var arena_buffer: [16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .limits = .{ .max_body_bytes = 256, .max_request_arena_bytes = 16 },
        .request = &request,
        .response = Response.init(fixed.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectError(error.PayloadTooLarge, context.multipart());
}

test "multipartStream maps arena exhaustion to PayloadTooLarge" {
    var headers = [_]netz.http1.Header{.{
        .name = "Content-Type",
        .value = "multipart/form-data; boundary=weft",
    }};
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var replay = ReplayReader{ .body = "--weft--\r\n" };
    var arena_buffer: [16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .limits = .{ .max_body_bytes = 256, .max_request_arena_bytes = 16 },
        .request = &request,
        .body_reader = .{ .replay = &replay },
        .response = Response.init(fixed.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectError(
        error.PayloadTooLarge,
        context.multipartStream(),
    );
}

test "body returns the cached streaming body" {
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var replay = ReplayReader{ .body = "hello" };
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .body_reader = .{ .replay = &replay },
        .response = Response.init(arena.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectEqualStrings("", context.body());
    try std.testing.expectEqualStrings("hello", try context.readBody());
    try std.testing.expectEqualStrings("hello", context.body());
}

test "json media type accepts parameters and structured suffixes" {
    try std.testing.expect(isJsonMediaType("application/json"));
    try std.testing.expect(isJsonMediaType("Application/JSON; charset=utf-8"));
    try std.testing.expect(isJsonMediaType(
        "application/problem+json",
    ));
    try std.testing.expect(isJsonMediaType(
        "application/vnd.api+json; profile=\"x\"",
    ));
    try std.testing.expect(!isJsonMediaType("text/plain"));
    try std.testing.expect(!isJsonMediaType("application/jsonx"));
    try std.testing.expect(!isJsonMediaType("json"));
    try std.testing.expect(!isJsonMediaType(""));
}

test "setCookie falls back to the arena for large values" {
    var request = netz.http1.Request{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = Response.init(arena.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    const long_value = try std.testing.allocator.alloc(u8, 700);
    defer std.testing.allocator.free(long_value);
    @memset(long_value, 'a');
    try context.setCookie(.{
        .name = "big",
        .value = long_value,
        .http_only = true,
    });

    const serialized = context.response.header("set-cookie").?;
    try std.testing.expect(serialized.len > 700);
    try std.testing.expect(std.mem.startsWith(u8, serialized, "big="));
    try std.testing.expect(std.mem.endsWith(u8, serialized, "; HttpOnly"));
}

test "decodedBody releases staging when the arena is too small" {
    const allocator = std.testing.allocator;
    const plain = try allocator.alloc(u8, 3000);
    defer allocator.free(plain);
    @memset(plain, 'a');

    var compressed_output = try std.Io.Writer.Allocating.initCapacity(
        allocator,
        64,
    );
    defer compressed_output.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var encoder = try std.compress.flate.Compress.init(
        &compressed_output.writer,
        &window,
        .gzip,
        .default,
    );
    try encoder.writer.writeAll(plain);
    try encoder.finish();

    var headers = [_]netz.http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var replay = ReplayReader{ .body = compressed_output.written() };
    // The compressed body fits the arena, but the decoded bytes do not.
    var arena_buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .request_allocator = allocator,
        .limits = .{ .max_body_bytes = 8192 },
        .request = &request,
        .body_reader = .{ .replay = &replay },
        .response = Response.init(fixed.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectError(
        error.PayloadTooLarge,
        context.decodedBody(),
    );
}

test "decodedBody stages growth outside a small arena" {
    const allocator = std.testing.allocator;
    const plain = try allocator.alloc(u8, 3000);
    defer allocator.free(plain);
    @memset(plain, 'a');

    var compressed_output = try std.Io.Writer.Allocating.initCapacity(
        allocator,
        64,
    );
    defer compressed_output.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var encoder = try std.compress.flate.Compress.init(
        &compressed_output.writer,
        &window,
        .gzip,
        .default,
    );
    try encoder.writer.writeAll(plain);
    try encoder.finish();

    var headers = [_]netz.http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var replay = ReplayReader{ .body = compressed_output.written() };
    var arena_buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .request_allocator = allocator,
        .limits = .{ .max_body_bytes = 8192 },
        .request = &request,
        .body_reader = .{ .replay = &replay },
        .response = Response.init(fixed.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    const decoded = try context.decodedBody();
    try std.testing.expectEqual(@as(usize, 3000), decoded.len);
    for (decoded) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
}
