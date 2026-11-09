const std = @import("std");
const netz = @import("netz");
const limits_mod = @import("limits.zig");
const stream_mod = @import("stream.zig");
const websocket_mod = @import("websocket.zig");

pub const Header = netz.http1.Header;
pub const StreamBody = stream_mod.Body;

/// Head room reserved for fields the HTTP/1 writer may add itself:
/// `Content-Length`, `Date`, and an optional `Connection`/`Trailer` field.
pub const head_bytes_overhead = 128;
pub const head_fields_overhead = 3;

/// A response being built by a handler or middleware.
///
/// The response is intentionally concrete: it holds the same `Header` type
/// Netz writes and is converted to Netz's `ResponseOptions` only at the
/// connection boundary. Header names and values are copied into the response
/// allocator, so a handler can pass slices with a shorter lifetime (including
/// stack buffers) without leaving dangling response fields.
pub const Response = struct {
    allocator: std.mem.Allocator,
    /// Optional allocator for transient growth (currently JSON serialization).
    /// When set, the final body is copied into `allocator` once so a bump
    /// allocator does not accumulate intermediate buffers.
    staging_allocator: ?std.mem.Allocator = null,
    max_body_bytes: usize,
    max_headers: usize,
    max_head_bytes: usize,
    status: u16 = 200,
    reason: []const u8 = "OK",
    headers: std.ArrayListUnmanaged(Header) = .empty,
    /// Trailer fields emitted after the body. Names and values are copied into
    /// the response allocator.
    trailers: std.ArrayListUnmanaged(Header) = .empty,
    trailer_bytes: usize = 0,
    body: []const u8 = "",
    /// Incremental body selected by a handler. Mutually exclusive with a
    /// buffered `body`.
    stream: ?stream_mod.Body = null,
    /// HTTP/1 WebSocket upgrade selected by a handler. Mutually exclusive with
    /// a buffered or streamed body.
    upgrade: ?websocket_mod.Upgrade = null,
    /// True when `body` was allocated by this response and must be released
    /// by `deinit` or `reset`.
    body_owned: bool = false,
    /// Sum of encoded header field bytes, excluding the status line.
    header_bytes: usize = 0,
    /// True once the application has selected a status, header, or body.
    /// The server uses this to decide whether an error should become a 500.
    committed: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_body_bytes: usize) Response {
        return initWithLimits(allocator, .{
            .max_response_bytes = max_body_bytes,
            .max_response_headers = std.math.maxInt(usize),
            .max_response_head_bytes = std.math.maxInt(usize),
        });
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        limits: limits_mod.Limits,
    ) Response {
        return .{
            .allocator = allocator,
            .max_body_bytes = limits.max_response_bytes,
            .max_headers = limits.max_response_headers -| head_fields_overhead,
            .max_head_bytes = limits.max_response_head_bytes -| head_bytes_overhead,
        };
    }

    pub fn deinit(self: *Response) void {
        self.cancelStream();
        self.cancelUpgrade();
        self.clearHeaders();
        self.clearTrailers();
        self.headers.deinit(self.allocator);
        self.trailers.deinit(self.allocator);
        if (self.body_owned) self.allocator.free(self.body);
        self.* = undefined;
    }

    /// Clear status, headers, and body while retaining the header list
    /// capacity. Used by recovery middleware before a response is committed.
    pub fn reset(self: *Response) void {
        self.cancelStream();
        self.cancelUpgrade();
        self.clearHeaders();
        self.clearTrailers();
        self.headers.clearRetainingCapacity();
        self.trailers.clearRetainingCapacity();
        self.trailer_bytes = 0;
        if (self.body_owned) self.allocator.free(self.body);
        self.body = "";
        self.body_owned = false;
        self.header_bytes = 0;
        self.status = 200;
        self.reason = "OK";
        self.committed = false;
    }

    pub fn setStatus(self: *Response, status: u16) void {
        // HTTP status codes are three digits in the 1xx-5xx classes. Reject
        // nonsense locally rather than letting it reach the wire encoder.
        self.status = if (status >= 100 and status <= 599) status else 500;
        self.reason = reasonFor(self.status);
        self.committed = true;
    }

    /// Set or replace a header field. Field names are matched
    /// case-insensitively, matching HTTP semantics.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try validateHeaderName(name);
        try validateHeaderValue(value);

        if (self.findHeader(name)) |index| {
            const old = self.headers.items[index];
            const value_copy = try self.allocator.dupe(u8, value);
            const next_bytes = self.header_bytes - old.value.len + value_copy.len;
            if (15 + self.reason.len + next_bytes > self.max_head_bytes) {
                self.allocator.free(value_copy);
                return error.ResponseHeadTooLarge;
            }
            self.allocator.free(old.value);
            self.headers.items[index].value = value_copy;
            self.header_bytes = next_bytes;
            self.committed = true;
            return;
        }

        try self.appendValidated(name, value);
    }

    /// Set a header only when the response does not already carry it. One
    /// lookup and one validation pass replace `hasHeader` followed by
    /// `setHeader` for middleware that supplies defaults.
    pub fn setHeaderIfAbsent(
        self: *Response,
        name: []const u8,
        value: []const u8,
    ) !void {
        try validateHeaderName(name);
        try validateHeaderValue(value);
        if (self.findHeader(name) != null) return;
        try self.appendValidated(name, value);
    }

    /// Append a header field, preserving duplicates. Use this for
    /// `Set-Cookie` and other list-valued fields.
    pub fn appendHeader(
        self: *Response,
        name: []const u8,
        value: []const u8,
    ) !void {
        try validateHeaderName(name);
        try validateHeaderValue(value);
        try self.appendValidated(name, value);
    }

    /// Append a field whose name and value the caller has already validated.
    fn appendValidated(
        self: *Response,
        name: []const u8,
        value: []const u8,
    ) !void {
        if (self.headers.items.len + 1 > self.max_headers) {
            return error.ResponseHeadersTooLarge;
        }

        const added = name.len + value.len + 4; // ": " + CRLF
        if (self.headSize() + added > self.max_head_bytes) {
            return error.ResponseHeadTooLarge;
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        try self.headers.append(self.allocator, .{
            .name = name_copy,
            .value = value_copy,
        });
        self.header_bytes += added;
        self.committed = true;
    }

    /// Append a trailer field emitted after the body. Trailer names and values
    /// use the same validation and budget as response headers.
    pub fn addTrailer(
        self: *Response,
        name: []const u8,
        value: []const u8,
    ) !void {
        try validateHeaderName(name);
        try validateHeaderValue(value);
        if (self.trailers.items.len + 1 > self.max_headers) {
            return error.ResponseHeadersTooLarge;
        }
        const added = name.len + value.len + 4;
        if (self.trailer_bytes + added > self.max_head_bytes) {
            return error.ResponseHeadTooLarge;
        }
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.trailers.append(self.allocator, .{
            .name = name_copy,
            .value = value_copy,
        });
        self.trailer_bytes += added;
        self.committed = true;
    }

    /// Set the body directly. The slice must remain valid until the response
    /// has been written; the request arena is the normal owner.
    /// Replace the response body with a borrowed slice. The bytes must outlive
    /// the response; allocate them in the request arena (or use `json`, which
    /// owns its allocation).
    pub fn setBody(self: *Response, body: []const u8) !void {
        if (self.stream != null) return error.StreamAlreadySet;
        if (self.upgrade != null) return error.UpgradeAlreadySet;
        if (body.len > self.max_body_bytes) return error.ResponseTooLarge;
        if (self.body_owned) self.allocator.free(self.body);
        self.body = body;
        self.body_owned = false;
        self.committed = true;
    }

    /// Release a buffered body while keeping status, headers, and trailers.
    /// Used by conditional-response middleware when switching to `304`.
    pub fn clearBody(self: *Response) void {
        if (self.body_owned) self.allocator.free(self.body);
        self.body = "";
        self.body_owned = false;
    }

    /// Set a text body. Like `setBody`, the slice is borrowed and must outlive
    /// the response (a literal, arena memory, or `ctx.arena.dupe`).
    pub fn text(self: *Response, body: []const u8) !void {
        if (self.stream != null) return error.StreamAlreadySet;
        if (self.upgrade != null) return error.UpgradeAlreadySet;
        // One lookup instead of `hasHeader` followed by a scanning
        // `setHeader`; the field is absent when this branch appends it.
        if (self.findHeader("content-type") == null) {
            try self.appendValidated(
                "Content-Type",
                "text/plain; charset=utf-8",
            );
        }
        try self.setBody(body);
    }

    pub fn json(self: *Response, value: anytype) !void {
        if (self.stream != null) return error.StreamAlreadySet;
        if (self.upgrade != null) return error.UpgradeAlreadySet;

        const staging = self.staging_allocator orelse self.allocator;
        var output = std.Io.Writer.Allocating.init(staging);
        // Unconditional: on success `toOwnedSlice` empties the buffer, so
        // `deinit` is a no-op; on any error it releases the staging bytes.
        defer output.deinit();
        std.json.Stringify.value(value, .{}, &output.writer) catch
            return error.OutOfMemory;
        const written = output.written();
        if (written.len > self.max_body_bytes) return error.ResponseTooLarge;

        const body = if (self.staging_allocator != null)
            self.allocator.dupe(u8, written) catch
                return error.OutOfMemory
        else
            output.toOwnedSlice() catch return error.OutOfMemory;
        errdefer self.allocator.free(body);
        if (self.findHeader("content-type") == null) {
            try self.appendValidated("Content-Type", "application/json");
        }
        if (self.body_owned) self.allocator.free(self.body);
        self.body = body;
        self.body_owned = true;
        self.committed = true;
    }

    pub fn hasHeader(self: *const Response, name: []const u8) bool {
        return self.findHeader(name) != null;
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        const index = self.findHeader(name) orelse return null;
        return self.headers.items[index].value;
    }

    pub fn removeHeader(self: *Response, name: []const u8) bool {
        const index = self.findHeader(name) orelse return false;
        const removed = self.headers.orderedRemove(index);
        self.header_bytes -= removed.name.len + removed.value.len + 4;
        self.allocator.free(removed.name);
        self.allocator.free(removed.value);
        return true;
    }

    /// Encoded status line plus header field bytes.
    pub fn headSize(self: *const Response) usize {
        // "HTTP/1.1 " + 3 status digits + " " + reason + CRLF
        return 15 + self.reason.len + self.header_bytes;
    }

    pub fn validateHead(self: *const Response) !void {
        if (self.headers.items.len > self.max_headers) {
            return error.ResponseHeadersTooLarge;
        }
        if (self.headSize() > self.max_head_bytes) {
            return error.ResponseHeadTooLarge;
        }
    }

    pub fn toOptions(
        self: *const Response,
        method: netz.http1.Method,
    ) netz.http1.runtime.ResponseOptions {
        return self.toOptionsFor(method, .http_1_1, false);
    }

    pub fn toOptionsFor(
        self: *const Response,
        method: netz.http1.Method,
        version: netz.http1.Version,
        request_accepts_trailers: bool,
    ) netz.http1.runtime.ResponseOptions {
        const emit_trailers = request_accepts_trailers and
            self.trailers.items.len != 0;
        return .{
            .version = version,
            .status = self.status,
            .reason = self.reason,
            .headers = self.headers.items,
            .body = self.body,
            .trailers = if (emit_trailers) self.trailers.items else &.{},
            .request_accepts_trailers = emit_trailers,
            .request_method = method,
        };
    }

    fn findHeader(self: *const Response, name: []const u8) ?usize {
        for (self.headers.items, 0..) |field, index| {
            if (std.ascii.eqlIgnoreCase(field.name, name)) return index;
        }
        return null;
    }

    fn clearHeaders(self: *Response) void {
        for (self.headers.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
    }

    fn clearTrailers(self: *Response) void {
        for (self.trailers.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        self.trailer_bytes = 0;
    }

    fn cancelStream(self: *Response) void {
        if (self.stream) |body| body.cancel();
        self.stream = null;
    }

    fn cancelUpgrade(self: *Response) void {
        if (self.upgrade) |upgrade| upgrade.cancel();
        self.upgrade = null;
    }
};

pub fn validateHeaderName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidHeaderName;
    for (name) |char| {
        if (!isTokenChar(char)) return error.InvalidHeaderName;
    }
}

pub fn validateHeaderValue(value: []const u8) !void {
    for (value) |char| {
        switch (char) {
            '\t' => {},
            0x20...0x7e => {},
            else => return error.InvalidHeaderValue,
        }
    }
}

fn isTokenChar(char: u8) bool {
    return switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn reasonFor(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        102 => "Processing",
        103 => "Early Hints",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        207 => "Multi-Status",
        208 => "Already Reported",
        226 => "IM Used",
        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        305 => "Use Proxy",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        407 => "Proxy Authentication Required",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        418 => "I'm a teapot",
        421 => "Misdirected Request",
        422 => "Unprocessable Content",
        423 => "Locked",
        424 => "Failed Dependency",
        425 => "Too Early",
        426 => "Upgrade Required",
        428 => "Precondition Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        451 => "Unavailable For Legal Reasons",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        506 => "Variant Also Negotiates",
        507 => "Insufficient Storage",
        508 => "Loop Detected",
        510 => "Not Extended",
        511 => "Network Authentication Required",
        else => "Unknown",
    };
}

test "response rejects out-of-range status codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var response = Response.init(arena.allocator(), 1024);

    response.setStatus(599);
    try std.testing.expectEqual(@as(u16, 599), response.status);
    response.setStatus(600);
    try std.testing.expectEqual(@as(u16, 500), response.status);
    response.setStatus(99);
    try std.testing.expectEqual(@as(u16, 500), response.status);
}

test "reason phrases cover common status codes" {
    try std.testing.expectEqualStrings("OK", reasonFor(200));
    try std.testing.expectEqualStrings("Not Found", reasonFor(404));
    try std.testing.expectEqualStrings(
        "Internal Server Error",
        reasonFor(500),
    );
}

test "response helpers commit and set headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var response = Response.init(arena.allocator(), 1024);
    try response.text("hello");
    try std.testing.expect(response.committed);
    try std.testing.expect(response.hasHeader("content-type"));
    try std.testing.expectEqualStrings("hello", response.body);
}

test "setHeaderIfAbsent keeps an existing field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var response = Response.init(arena.allocator(), 1024);

    try response.setHeaderIfAbsent("X-Test", "one");
    try response.setHeaderIfAbsent("x-test", "two");
    try std.testing.expectEqualStrings("one", response.header("X-Test").?);
    try std.testing.expectEqual(@as(usize, 1), response.headers.items.len);
    try std.testing.expectError(
        error.InvalidHeaderName,
        response.setHeaderIfAbsent("Bad Name", "x"),
    );
}

test "response header limits and replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var response = Response.initWithLimits(arena.allocator(), .{
        .max_response_bytes = 1024,
        .max_response_headers = 5,
        .max_response_head_bytes = 512,
    });

    try response.setHeader("X-A", "one");
    try response.setHeader("x-a", "two");
    try std.testing.expectEqualStrings("two", response.header("X-A").?);
    try std.testing.expectEqual(@as(usize, 1), response.headers.items.len);

    try response.setHeader("X-B", "three");
    try std.testing.expectError(
        error.ResponseHeadersTooLarge,
        response.setHeader("X-C", "four"),
    );
    try std.testing.expectError(
        error.InvalidHeaderName,
        response.setHeader("Bad Name", "x"),
    );
    try std.testing.expectError(
        error.InvalidHeaderValue,
        response.setHeader("X-Inject", "a\r\nb"),
    );
}

test "response reset cancels a pending stream" {
    const State = struct {
        var cancelled: bool = false;

        fn cancel(_: ?*anyopaque) void {
            cancelled = true;
        }

        fn write(_: ?*anyopaque, _: *@import("stream.zig").Writer) anyerror!void {}
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var response = Response.init(arena.allocator(), 1024);
    response.stream = .{ .write_fn = State.write, .cancel_fn = State.cancel };
    State.cancelled = false;
    response.reset();
    try std.testing.expect(State.cancelled);
    try std.testing.expect(response.stream == null);
}

test "response reset releases committed state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var response = Response.init(arena.allocator(), 1024);
    try response.setHeader("X-Test", "yes");
    response.setStatus(418);
    try response.text("tea");
    response.reset();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(!response.committed);
    try std.testing.expectEqualStrings("", response.body);
    try std.testing.expect(!response.hasHeader("x-test"));
}

test "response trailers are validated and gated by request acceptance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var response = Response.init(arena.allocator(), 1024);

    try response.addTrailer("X-Checksum", "abc");
    const accepted = response.toOptionsFor(.GET, .http_1_1, true);
    try std.testing.expectEqual(@as(usize, 1), accepted.trailers.len);
    try std.testing.expect(accepted.request_accepts_trailers);

    const refused = response.toOptionsFor(.GET, .http_1_1, false);
    try std.testing.expectEqual(@as(usize, 0), refused.trailers.len);
    try std.testing.expect(!refused.request_accepts_trailers);

    try std.testing.expectError(
        error.InvalidHeaderValue,
        response.addTrailer("X-Bad", "a\r\nb"),
    );
}

test "json releases staging when serialization fails" {
    const testImpl = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var response = Response.init(allocator, 1024 * 1024);
            defer response.deinit();
            try response.json(.{ .data = "abcdef" });
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testImpl.run,
        .{},
    );
}

test "json serialization stages growth outside a small arena" {
    var arena_buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var response = Response.initWithLimits(fixed.allocator(), .{
        .max_response_bytes = 8192,
        .max_response_headers = 16,
        .max_response_head_bytes = 1024,
    });
    response.staging_allocator = std.testing.allocator;

    const text = try std.testing.allocator.alloc(u8, 3000);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    try response.json(.{ .data = text });
    try std.testing.expect(response.body.len > 3000);
    try std.testing.expectEqualStrings(
        "{\"data\":\"",
        response.body[0..9],
    );
    try std.testing.expectEqual(
        @as(u8, '}'),
        response.body[response.body.len - 1],
    );
}
