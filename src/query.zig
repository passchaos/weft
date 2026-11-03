const std = @import("std");

/// One decoded query-string pair. Repeated names are preserved in order.
pub const Pair = struct {
    name: []const u8,
    value: []const u8,
};

/// Owned decoded query pairs. `deinit` releases every component; request
/// handling normally allocates from the request arena and skips this call.
pub const Query = struct {
    pairs: []const Pair = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Query) void {
        if (self.allocator) |allocator| {
            for (self.pairs) |pair| {
                allocator.free(pair.name);
                allocator.free(pair.value);
            }
            allocator.free(self.pairs);
        }
        self.* = .{};
    }
};

/// Decode `%XX` escapes and optionally treat `+` as a space.
///
/// Control bytes, including NUL and DEL, are rejected after decoding so an
/// application never receives a value that can corrupt logs or downstream
/// protocols. Non-ASCII bytes are passed through as UTF-8. The returned slice
/// is an exact-size allocation owned by `allocator`.
pub fn decodeComponent(
    allocator: std.mem.Allocator,
    text: []const u8,
    plus_as_space: bool,
) ![]const u8 {
    // Validate and size the result before allocating so malformed input has no
    // cleanup burden and the returned slice is exactly freeable.
    var decoded_len = text.len;
    var input_index: usize = 0;
    while (input_index < text.len) {
        const char = text[input_index];
        if (char == '%') {
            if (input_index + 2 >= text.len) {
                return error.InvalidPercentEncoding;
            }
            const high = hexDigit(text[input_index + 1]) orelse
                return error.InvalidPercentEncoding;
            const low = hexDigit(text[input_index + 2]) orelse
                return error.InvalidPercentEncoding;
            if (!isVisible(high * 16 + low)) {
                return error.InvalidPercentEncoding;
            }
            decoded_len -= 2;
            input_index += 3;
            continue;
        }
        if (!isVisible(char)) return error.InvalidPercentEncoding;
        input_index += 1;
    }

    const output = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(output);

    input_index = 0;
    var output_index: usize = 0;
    while (input_index < text.len) {
        const char = text[input_index];
        if (char == '%') {
            const high = hexDigit(text[input_index + 1]).?;
            const low = hexDigit(text[input_index + 2]).?;
            output[output_index] = high * 16 + low;
            input_index += 3;
        } else if (char == '+' and plus_as_space) {
            output[output_index] = ' ';
            input_index += 1;
        } else {
            output[output_index] = char;
            input_index += 1;
        }
        output_index += 1;
    }

    return output;
}

/// Parse an `application/x-www-form-urlencoded`-style query string.
///
/// Values are percent-decoded and `+` is decoded as a space. The caller owns
/// the returned `Query`.
pub fn parse(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_pairs: usize,
) !Query {
    if (text.len == 0) return .{};

    var pairs = std.ArrayListUnmanaged(Pair).empty;
    errdefer {
        for (pairs.items) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        pairs.deinit(allocator);
    }

    var iterator = std.mem.splitScalar(u8, text, '&');
    while (iterator.next()) |part| {
        if (part.len == 0) continue;
        if (pairs.items.len >= max_pairs) return error.TooManyQueryParams;

        const equals = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const name = try decodeComponent(allocator, part[0..equals], true);
        const value = decodeComponent(
            allocator,
            if (equals < part.len) part[equals + 1 ..] else "",
            true,
        ) catch |err| {
            allocator.free(name);
            return err;
        };
        pairs.append(allocator, .{ .name = name, .value = value }) catch |err| {
            allocator.free(name);
            allocator.free(value);
            return err;
        };
    }

    return .{
        .pairs = try pairs.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn hexDigit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

fn isVisible(char: u8) bool {
    return char == '\t' or (char >= 0x20 and char != 0x7f);
}

test "query parsing decodes percent escapes and plus" {
    const allocator = std.testing.allocator;
    var parsed = try parse(allocator, "q=hello+world&lang=zh&empty", 8);
    defer parsed.deinit();
    const pairs = parsed.pairs;

    try std.testing.expectEqual(@as(usize, 3), pairs.len);
    try std.testing.expectEqualStrings("q", pairs[0].name);
    try std.testing.expectEqualStrings("hello world", pairs[0].value);
    try std.testing.expectEqualStrings("lang", pairs[1].name);
    try std.testing.expectEqualStrings("zh", pairs[1].value);
    try std.testing.expectEqualStrings("empty", pairs[2].name);
    try std.testing.expectEqualStrings("", pairs[2].value);
}

test "query parsing rejects bounds and control bytes" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.TooManyQueryParams,
        parse(allocator, "a=1&b=2", 1),
    );
    try std.testing.expectError(
        error.InvalidPercentEncoding,
        parse(allocator, "a=%00", 8),
    );
    try std.testing.expectError(
        error.InvalidPercentEncoding,
        parse(allocator, "a=%zz", 8),
    );
    try std.testing.expectError(
        error.InvalidPercentEncoding,
        parse(allocator, "a=%", 8),
    );
}
