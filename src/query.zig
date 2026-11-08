const std = @import("std");

/// One decoded query-string pair. Repeated names are preserved in order.
pub const Pair = struct {
    name: []const u8,
    value: []const u8,
};

/// Owned decoded query pairs. `deinit` releases the pair array and, when any
/// component needed decoding, the single buffer holding decoded bytes.
/// Request handling normally allocates from the request arena and skips this
/// call. When `components` is null every pair borrows the input text.
pub const Query = struct {
    pairs: []const Pair = &.{},
    allocator: ?std.mem.Allocator = null,
    components: ?[]u8 = null,

    pub fn deinit(self: *Query) void {
        if (self.allocator) |allocator| {
            if (self.components) |buffer| allocator.free(buffer);
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

    // First pass: validate every component and learn whether any of them
    // needs `%XX`/`+` decoding. Plain queries then borrow the input text and
    // allocate only the pair array.
    var pair_count: usize = 0;
    var needs_decode = false;
    var scan = std.mem.splitScalar(u8, text, '&');
    while (scan.next()) |part| {
        if (part.len == 0) continue;
        if (pair_count >= max_pairs) return error.TooManyQueryParams;
        pair_count += 1;
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        if (try scanComponent(part[0..equals])) needs_decode = true;
        if (try scanComponent(
            if (equals < part.len) part[equals + 1 ..] else "",
        )) needs_decode = true;
    }
    if (pair_count == 0) return .{};

    const pairs = try allocator.alloc(Pair, pair_count);
    errdefer allocator.free(pairs);

    var components: ?[]u8 = null;
    if (needs_decode) {
        // Decoded output is never longer than the input.
        const buffer = try allocator.alloc(u8, text.len);
        components = buffer;
        errdefer allocator.free(buffer);
    }

    var offset: usize = 0;
    var index: usize = 0;
    var iterator = std.mem.splitScalar(u8, text, '&');
    while (iterator.next()) |part| {
        if (part.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const raw_name = part[0..equals];
        const raw_value = if (equals < part.len) part[equals + 1 ..] else "";
        if (components) |buffer| {
            const name = decodeInto(raw_name, buffer, &offset);
            const value = decodeInto(raw_value, buffer, &offset);
            pairs[index] = .{ .name = name, .value = value };
        } else {
            pairs[index] = .{ .name = raw_name, .value = raw_value };
        }
        index += 1;
    }

    return .{
        .pairs = pairs,
        .allocator = allocator,
        .components = components,
    };
}

/// Decode like `decodeComponent`, but borrow `text` when it needs no
/// escape or plus-space rewrite. The caller must keep `text` alive when the
/// result points into it.
pub fn decodeComponentBorrowed(
    allocator: std.mem.Allocator,
    text: []const u8,
    plus_as_space: bool,
) ![]const u8 {
    if (!try needsComponentDecode(text, plus_as_space)) return text;
    return decodeComponent(allocator, text, plus_as_space);
}

/// Validate one component and report whether it contains an escape.
fn scanComponent(text: []const u8) !bool {
    return needsComponentDecode(text, true);
}

fn needsComponentDecode(text: []const u8, plus_as_space: bool) !bool {
    var needs_decode = false;
    var index: usize = 0;
    while (index < text.len) {
        const char = text[index];
        if (char == '%') {
            if (index + 2 >= text.len) return error.InvalidPercentEncoding;
            const high = hexDigit(text[index + 1]) orelse
                return error.InvalidPercentEncoding;
            const low = hexDigit(text[index + 2]) orelse
                return error.InvalidPercentEncoding;
            if (!isVisible(high * 16 + low)) {
                return error.InvalidPercentEncoding;
            }
            needs_decode = true;
            index += 3;
            continue;
        }
        if (plus_as_space and char == '+') needs_decode = true;
        if (!isVisible(char)) return error.InvalidPercentEncoding;
        index += 1;
    }
    return needs_decode;
}

/// Decode one component into `buffer` at `offset`. The caller has already
/// validated the input with `scanComponent`.
fn decodeInto(
    text: []const u8,
    buffer: []u8,
    offset: *usize,
) []const u8 {
    const start = offset.*;
    var index: usize = 0;
    while (index < text.len) {
        const char = text[index];
        if (char == '%') {
            const high = hexDigit(text[index + 1]).?;
            const low = hexDigit(text[index + 2]).?;
            buffer[offset.*] = high * 16 + low;
            offset.* += 1;
            index += 3;
        } else if (char == '+') {
            buffer[offset.*] = ' ';
            offset.* += 1;
            index += 1;
        } else {
            buffer[offset.*] = char;
            offset.* += 1;
            index += 1;
        }
    }
    return buffer[start..offset.*];
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

test "query parsing borrows plain text and decodes mixed input into one buffer" {
    const allocator = std.testing.allocator;

    var plain = try parse(allocator, "a=1&b=two", 8);
    defer plain.deinit();
    try std.testing.expect(plain.components == null);
    try std.testing.expectEqual(@as(usize, 2), plain.pairs.len);
    try std.testing.expectEqualStrings("two", plain.pairs[1].value);

    var mixed = try parse(allocator, "a=1&b=%20c&d=+e", 8);
    defer mixed.deinit();
    try std.testing.expect(mixed.components != null);
    try std.testing.expectEqualStrings("1", mixed.pairs[0].value);
    try std.testing.expectEqualStrings(" c", mixed.pairs[1].value);
    try std.testing.expectEqualStrings(" e", mixed.pairs[2].value);

    var escaped_name = try parse(allocator, "a%20b=c", 8);
    defer escaped_name.deinit();
    try std.testing.expectEqualStrings("a b", escaped_name.pairs[0].name);
}

test "query parsing is total for arbitrary bytes" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed_1234);
    const random = prng.random();

    var buffer: [64]u8 = undefined;
    for (0..500) |_| {
        const length = random.intRangeAtMost(usize, 0, buffer.len);
        random.bytes(buffer[0..length]);
        const text = buffer[0..length];

        var parsed = parse(allocator, text, 8) catch continue;
        defer parsed.deinit();
        try std.testing.expect(parsed.pairs.len <= 8);
        for (parsed.pairs) |pair| {
            for (pair.name) |byte| {
                try std.testing.expect(byte == '\t' or
                    (byte >= 0x20 and byte != 0x7f));
            }
            for (pair.value) |byte| {
                try std.testing.expect(byte == '\t' or
                    (byte >= 0x20 and byte != 0x7f));
            }
        }
    }
}

test "borrowed component decoding avoids allocation without escapes" {
    const plain = "plain";
    const borrowed = try decodeComponentBorrowed(
        std.testing.allocator,
        plain,
        false,
    );
    try std.testing.expect(borrowed.ptr == plain.ptr);

    const plus_text = "a+b";
    const plus_borrowed = try decodeComponentBorrowed(
        std.testing.allocator,
        plus_text,
        false,
    );
    try std.testing.expectEqualStrings(plus_text, plus_borrowed);
    try std.testing.expect(plus_borrowed.ptr == plus_text.ptr);

    const decoded = try decodeComponentBorrowed(
        std.testing.allocator,
        "a+b%20c",
        true,
    );
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a b c", decoded);

    try std.testing.expectError(
        error.InvalidPercentEncoding,
        decodeComponentBorrowed(std.testing.allocator, "a%zz", false),
    );
}
