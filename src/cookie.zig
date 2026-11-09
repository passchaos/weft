const std = @import("std");
const netz = @import("netz");

/// Maximum `Cookie` header bytes inspected for one request.
pub const max_header_bytes = 4096;

pub const SameSite = enum {
    strict,
    lax,
    none,

    fn text(self: SameSite) []const u8 {
        return switch (self) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        };
    }
};

/// A cookie to serialize into a `Set-Cookie` field.
pub const SetCookie = struct {
    name: []const u8,
    value: []const u8,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    max_age: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,
    /// Optional preformatted `Expires` date, e.g. `Thu, 01 Jan 1970 00:00:00 GMT`.
    expires: ?[]const u8 = null,
    /// CHIPS partitioned cookie. Requires `secure`.
    partitioned: bool = false,
};

/// Find the first cookie with `name` across all `Cookie` request fields.
pub fn find(
    headers: []const netz.http1.Header,
    name: []const u8,
) ?[]const u8 {
    if (name.len == 0) return null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "cookie")) continue;
        if (header.value.len > max_header_bytes) continue;

        var parts = std.mem.splitScalar(u8, header.value, ';');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse
                continue;
            if (std.mem.eql(u8, trimmed[0..equals], name)) {
                const value = std.mem.trim(
                    u8,
                    trimmed[equals + 1 ..],
                    " \t",
                );
                // RFC 6265 allows a DQUOTE-wrapped cookie-value; expose the
                // octets without the quotes.
                if (value.len >= 2 and
                    value[0] == '"' and
                    value[value.len - 1] == '"')
                {
                    return value[1 .. value.len - 1];
                }
                return value;
            }
        }
    }
    return null;
}

/// Serialize a `Set-Cookie` field value into the response arena.
pub fn serialize(
    allocator: std.mem.Allocator,
    cookie: SetCookie,
) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    // An allocating writer reports allocator failure as `WriteFailed`;
    // normalize it so callers can handle `OutOfMemory` like other helpers.
    write(&output.writer, cookie) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    return output.toOwnedSlice();
}

/// Write a serialized `Set-Cookie` field value to `writer`.
///
/// Validation happens before any bytes are written, so a rejected cookie does
/// not leave a partial value in the caller's buffer.
pub fn write(writer: *std.Io.Writer, cookie: SetCookie) !void {
    try validateName(cookie.name);
    try validateValue(cookie.value);
    if (cookie.same_site == .none and !cookie.secure) {
        return error.InsecureSameSiteNone;
    }
    if (cookie.partitioned and !cookie.secure) {
        return error.InsecurePartitioned;
    }
    try validatePrefix(cookie);

    try writer.writeAll(cookie.name);
    try writer.writeByte('=');
    try writer.writeAll(cookie.value);

    if (cookie.path) |path| {
        try validateAttribute(path);
        try writer.writeAll("; Path=");
        try writer.writeAll(path);
    }
    if (cookie.domain) |domain| {
        try validateAttribute(domain);
        try writer.writeAll("; Domain=");
        try writer.writeAll(domain);
    }
    if (cookie.max_age) |seconds| {
        try writer.print("; Max-Age={d}", .{seconds});
    }
    if (cookie.expires) |expires| {
        try validateAttribute(expires);
        try writer.writeAll("; Expires=");
        try writer.writeAll(expires);
    }
    if (cookie.secure) try writer.writeAll("; Secure");
    if (cookie.http_only) try writer.writeAll("; HttpOnly");
    if (cookie.same_site) |same_site| {
        try writer.writeAll("; SameSite=");
        try writer.writeAll(same_site.text());
    }
    if (cookie.partitioned) try writer.writeAll("; Partitioned");
}

/// Enforce the RFC 6265bis `__Secure-` and `__Host-` cookie prefixes.
fn validatePrefix(cookie: SetCookie) !void {
    if (std.mem.startsWith(u8, cookie.name, "__Host-")) {
        if (!cookie.secure) return error.InsecureCookiePrefix;
        if (cookie.domain != null) return error.InvalidCookiePrefix;
        const path = cookie.path orelse return error.InvalidCookiePrefix;
        if (!std.mem.eql(u8, path, "/")) return error.InvalidCookiePrefix;
        return;
    }
    if (std.mem.startsWith(u8, cookie.name, "__Secure-")) {
        if (!cookie.secure) return error.InsecureCookiePrefix;
    }
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidCookieName;
    for (name) |char| {
        if (!isTokenChar(char)) return error.InvalidCookieName;
    }
}

fn validateValue(value: []const u8) !void {
    for (value) |char| {
        if (char < 0x21 or char > 0x7e) return error.InvalidCookieValue;
        switch (char) {
            '"', ',', ';', '\\' => return error.InvalidCookieValue,
            else => {},
        }
    }
}

fn validateAttribute(value: []const u8) !void {
    for (value) |char| {
        if (char < 0x20 or char == 0x7f or char == ';') {
            return error.InvalidCookieAttribute;
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

test "cookie serialization releases ownership on allocation failure" {
    const testImpl = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const value = try serialize(allocator, .{
                .name = "session",
                .value = "abc",
                .path = "/",
                .max_age = 3600,
                .http_only = true,
                .secure = true,
                .same_site = .lax,
            });
            allocator.free(value);
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testImpl.run,
        .{},
    );
}

test "cookie lookup scans multiple headers" {
    const headers = [_]netz.http1.Header{
        .{ .name = "Cookie", .value = "theme=dark; session=abc" },
        .{ .name = "cookie", .value = "lang=zh" },
    };
    try std.testing.expectEqualStrings("dark", find(&headers, "theme").?);
    try std.testing.expectEqualStrings("abc", find(&headers, "session").?);
    try std.testing.expectEqualStrings("zh", find(&headers, "lang").?);
    try std.testing.expect(find(&headers, "missing") == null);
}

test "cookie lookup unwraps quoted values" {
    const headers = [_]netz.http1.Header{
        .{ .name = "Cookie", .value = "q=\"hello\"; bad=\"open" },
    };
    try std.testing.expectEqualStrings("hello", find(&headers, "q").?);
    try std.testing.expectEqualStrings("\"open", find(&headers, "bad").?);
}

test "cookie serialization includes attributes" {
    const allocator = std.testing.allocator;
    const value = try serialize(allocator, .{
        .name = "session",
        .value = "abc123",
        .path = "/",
        .max_age = 3600,
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });
    defer allocator.free(value);
    try std.testing.expectEqualStrings(
        "session=abc123; Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=Lax",
        value,
    );
}

test "cookie validation rejects injection" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidCookieValue,
        serialize(allocator, .{ .name = "a", .value = "x\r\ny" }),
    );
    try std.testing.expectError(
        error.InvalidCookieName,
        serialize(allocator, .{ .name = "bad name", .value = "x" }),
    );
}

test "cookie prefixes and partitioned attributes are enforced" {
    const allocator = std.testing.allocator;

    const secure = try serialize(allocator, .{
        .name = "__Secure-session",
        .value = "abc",
        .secure = true,
    });
    defer allocator.free(secure);
    try std.testing.expect(std.mem.indexOf(u8, secure, "; Secure") != null);

    try std.testing.expectError(
        error.InsecureCookiePrefix,
        serialize(allocator, .{
            .name = "__Secure-session",
            .value = "abc",
        }),
    );
    try std.testing.expectError(
        error.InsecureCookiePrefix,
        serialize(allocator, .{
            .name = "__Host-session",
            .value = "abc",
        }),
    );
    try std.testing.expectError(
        error.InvalidCookiePrefix,
        serialize(allocator, .{
            .name = "__Host-session",
            .value = "abc",
            .secure = true,
            .path = "/app",
        }),
    );

    const host = try serialize(allocator, .{
        .name = "__Host-session",
        .value = "abc",
        .secure = true,
        .path = "/",
        .partitioned = true,
    });
    defer allocator.free(host);
    try std.testing.expect(std.mem.indexOf(u8, host, "; Partitioned") != null);

    try std.testing.expectError(
        error.InsecurePartitioned,
        serialize(allocator, .{
            .name = "session",
            .value = "abc",
            .partitioned = true,
        }),
    );
}
