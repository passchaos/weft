const std = @import("std");
const netz = @import("netz");

pub const Header = netz.http1.Header;

/// A response being built by a handler or middleware.
///
/// The response is intentionally concrete: it holds the same `Header` type
/// Netz writes and is converted to Netz's `ResponseOptions` only at the
/// connection boundary. That keeps middleware composition free of generic
/// request/response types.
pub const Response = struct {
    allocator: std.mem.Allocator,
    max_body_bytes: usize,
    status: u16 = 200,
    reason: []const u8 = "OK",
    headers: std.ArrayListUnmanaged(Header) = .empty,
    body: []const u8 = "",
    /// True once the application has selected a status, header, or body.
    /// The server uses this to decide whether an error should become a 500.
    committed: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_body_bytes: usize) Response {
        return .{
            .allocator = allocator,
            .max_body_bytes = max_body_bytes,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setStatus(self: *Response, status: u16) void {
        self.status = status;
        self.reason = reasonFor(status);
        self.committed = true;
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.append(self.allocator, .{
            .name = name,
            .value = value,
        });
        self.committed = true;
    }

    /// Set the body directly. The slice must remain valid until the response
    /// has been written; the request arena is the normal owner.
    pub fn setBody(self: *Response, body: []const u8) !void {
        if (body.len > self.max_body_bytes) return error.ResponseTooLarge;
        self.body = body;
        self.committed = true;
    }

    pub fn text(self: *Response, body: []const u8) !void {
        if (!self.hasHeader("content-type")) {
            try self.setHeader("Content-Type", "text/plain; charset=utf-8");
        }
        try self.setBody(body);
    }

    pub fn json(self: *Response, value: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(
            self.allocator,
            value,
            .{},
        );
        if (body.len > self.max_body_bytes) return error.ResponseTooLarge;
        if (!self.hasHeader("content-type")) {
            try self.setHeader("Content-Type", "application/json");
        }
        self.body = body;
        self.committed = true;
    }

    pub fn hasHeader(self: *const Response, name: []const u8) bool {
        for (self.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
        }
        return false;
    }

    pub fn toOptions(
        self: *const Response,
        method: netz.http1.Method,
    ) netz.http1.runtime.ResponseOptions {
        return .{
            .status = self.status,
            .reason = self.reason,
            .headers = self.headers.items,
            .body = self.body,
            .request_method = method,
        };
    }
};

pub fn reasonFor(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        418 => "I'm a teapot",
        422 => "Unprocessable Content",
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
        else => "Unknown",
    };
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
