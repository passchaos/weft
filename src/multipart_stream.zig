//! Bounded incremental `multipart/form-data` parsing.
//!
//! Unlike `multipart.parse`, this parser never holds the whole body in memory.
//! It pulls chunks from a `Source`, keeps a fixed-size window, and exposes one
//! part at a time with a `DataReader` for its payload. Total bytes, part count,
//! and per-part header bytes are all bounded by `Options`.

const std = @import("std");
const multipart = @import("multipart.zig");

pub const Header = multipart.Header;

/// Pull source for raw body bytes. `next` returns null at end of body.
pub const Source = struct {
    context: ?*anyopaque = null,
    next_fn: *const fn (?*anyopaque) anyerror!?[]const u8,

    pub fn next(self: Source) anyerror!?[]const u8 {
        return self.next_fn(self.context);
    }
};

pub const Options = struct {
    max_parts: usize = 64,
    max_headers_per_part: usize = 16,
    max_header_bytes: usize = 8 * 1024,
    /// Total body bytes accepted across all parts.
    max_body_bytes: usize = 16 * 1024 * 1024,
    /// Fixed parse window. Must be at least `boundary + 8` bytes.
    buffer_bytes: usize = 32 * 1024,
};

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    headers: []const Header,
    /// Part payload puller. Valid until the next `nextPart` call.
    data: *DataReader,
};

pub const Stream = struct {
    allocator: std.mem.Allocator,
    source: Source,
    options: Options,
    delimiter: []u8,
    next_delimiter: []u8,
    buffer: []u8,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,
    total_bytes: usize = 0,
    /// Remainder of the last source chunk that did not fit in the window.
    pending: []const u8 = &.{},
    part_count: usize = 0,
    need_initial: bool = true,
    finished: bool = false,
    /// True while the caller owns the current part's data reader.
    in_part: bool = false,
    data_reader: DataReader = undefined,
    part_name: ?[]const u8 = null,
    part_filename: ?[]const u8 = null,
    part_content_type: ?[]const u8 = null,
    part_headers: []Header = &.{},

    /// Parse `content_type` and allocate the fixed window.
    pub fn init(
        allocator: std.mem.Allocator,
        source: Source,
        content_type: []const u8,
        options: Options,
    ) !Stream {
        const boundary = try multipart.boundaryFromContentType(
            allocator,
            content_type,
        );
        errdefer allocator.free(boundary);
        const delimiter = try std.fmt.allocPrint(
            allocator,
            "--{s}",
            .{boundary},
        );
        errdefer allocator.free(delimiter);
        const next_delimiter = try std.fmt.allocPrint(
            allocator,
            "\r\n--{s}",
            .{boundary},
        );
        errdefer allocator.free(next_delimiter);
        allocator.free(boundary);

        if (options.buffer_bytes <= next_delimiter.len + 8) {
            return error.InvalidMultipart;
        }
        const buffer = try allocator.alloc(u8, options.buffer_bytes);
        errdefer allocator.free(buffer);

        return .{
            .allocator = allocator,
            .source = source,
            .options = options,
            .delimiter = delimiter,
            .next_delimiter = next_delimiter,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.freePart();
        self.allocator.free(self.delimiter);
        self.allocator.free(self.next_delimiter);
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    /// Advance to the next part. Returns null after the closing delimiter.
    pub fn nextPart(self: *Stream) !?Part {
        if (self.finished) return null;
        if (self.in_part) {
            // A caller may stop reading part data early (for example after a
            // bound violation). Skip the remainder so the next part starts at
            // a delimiter.
            while (try self.data_reader.next()) |_| {}
        }
        self.freePart();

        if (self.need_initial) {
            try self.consumeInitialDelimiter();
            self.need_initial = false;
        }

        try self.ensure(2);
        if (self.buffer[self.start] == '-') {
            if (self.end - self.start < 2 or self.buffer[self.start + 1] != '-') {
                return error.InvalidMultipart;
            }
            self.start += 2;
            self.finished = true;
            return null;
        }
        if (self.buffer[self.start] != '\r' or
            self.buffer[self.start + 1] != '\n')
        {
            return error.InvalidMultipart;
        }
        self.start += 2;

        try self.parsePartHeaders();
        if (self.part_count >= self.options.max_parts) {
            return error.TooManyParts;
        }
        self.part_count += 1;

        self.data_reader = .{ .stream = self };
        self.in_part = true;
        return .{
            .name = self.part_name.?,
            .filename = self.part_filename,
            .content_type = self.part_content_type,
            .headers = self.part_headers,
            .data = &self.data_reader,
        };
    }

    fn freePart(self: *Stream) void {
        if (self.part_name) |name| self.allocator.free(name);
        if (self.part_filename) |filename| self.allocator.free(filename);
        if (self.part_content_type) |value| self.allocator.free(value);
        for (self.part_headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        if (self.part_headers.len != 0) self.allocator.free(self.part_headers);
        self.part_name = null;
        self.part_filename = null;
        self.part_content_type = null;
        self.part_headers = &.{};
    }

    fn consumeInitialDelimiter(self: *Stream) !void {
        while (true) {
            if (self.end - self.start >= self.delimiter.len and
                std.mem.startsWith(
                    u8,
                    self.buffer[self.start..self.end],
                    self.delimiter,
                ))
            {
                self.start += self.delimiter.len;
                return;
            }
            if (findDelimiter(
                self.buffer[self.start..self.end],
                self.next_delimiter,
            )) |found| {
                self.start += found + self.next_delimiter.len;
                return;
            }
            if (!try self.fillMore()) {
                return error.InvalidMultipart;
            }
        }
    }

    fn parsePartHeaders(self: *Stream) !void {
        var header_bytes: usize = 0;
        var scanned: usize = 0;
        while (true) {
            const window = self.buffer[self.start..self.end];
            if (std.mem.indexOfPos(u8, window, scanned, "\r\n\r\n")) |found| {
                const block = window[0..found];
                if (block.len > self.options.max_header_bytes) {
                    return error.InvalidMultipart;
                }
                self.start += found + 4;
                try self.parseHeaderBlock(block);
                return;
            }
            // Re-scan the last three bytes: a CRLFCRLF can straddle the
            // previous window end and newly filled bytes.
            scanned = window.len - @min(window.len, 3);
            header_bytes = window.len;
            if (header_bytes > self.options.max_header_bytes) {
                return error.InvalidMultipart;
            }
            if (!try self.fillMore()) {
                return error.InvalidMultipart;
            }
        }
    }

    fn parseHeaderBlock(self: *Stream, block: []const u8) !void {
        var headers = std.ArrayListUnmanaged(Header).empty;
        errdefer {
            for (headers.items) |header| {
                self.allocator.free(header.name);
                self.allocator.free(header.value);
            }
            headers.deinit(self.allocator);
        }

        var name: ?[]const u8 = null;
        errdefer if (name) |value| self.allocator.free(value);
        var filename: ?[]const u8 = null;
        errdefer if (filename) |value| self.allocator.free(value);
        var content_type_value: ?[]const u8 = null;
        var content_type_owned: ?[]const u8 = null;
        errdefer if (content_type_owned) |value| self.allocator.free(value);

        var lines = std.mem.splitSequence(u8, block, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (headers.items.len >= self.options.max_headers_per_part) {
                return error.InvalidMultipart;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse
                return error.InvalidMultipart;
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            try headers.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, header_name),
                .value = try self.allocator.dupe(u8, header_value),
            });

            if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
                try multipart.parseDisposition(
                    self.allocator,
                    header_value,
                    &name,
                    &filename,
                );
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
                if (content_type_owned != null) return error.InvalidMultipart;
                content_type_owned = try self.allocator.dupe(
                    u8,
                    header_value,
                );
                content_type_value = content_type_owned;
            }
        }

        self.part_name = name orelse return error.InvalidMultipart;
        if (self.part_name.?.len == 0) return error.InvalidMultipart;
        self.part_filename = filename;
        self.part_content_type = content_type_value;
        self.part_headers = try headers.toOwnedSlice(self.allocator);
    }

    /// Ensure at least `wanted` buffered bytes, filling from the source.
    fn ensure(self: *Stream, wanted: usize) !void {
        while (self.end - self.start < wanted) {
            if (!try self.fillMore()) return error.InvalidMultipart;
        }
    }

    /// Fill more bytes from the source. Returns false at EOF with no progress.
    fn fillMore(self: *Stream) !bool {
        if (self.start != 0) {
            const remaining = self.end - self.start;
            std.mem.copyForwards(
                u8,
                self.buffer[0..remaining],
                self.buffer[self.start..self.end],
            );
            self.start = 0;
            self.end = remaining;
        }

        if (self.pending.len != 0) {
            if (self.end == self.buffer.len) return false;
            const copy = @min(
                self.pending.len,
                self.buffer.len - self.end,
            );
            @memcpy(self.buffer[self.end..][0..copy], self.pending[0..copy]);
            self.end += copy;
            self.pending = self.pending[copy..];
            return true;
        }

        if (self.eof or self.end == self.buffer.len) return false;
        const chunk = (try self.source.next()) orelse {
            self.eof = true;
            return false;
        };
        if (chunk.len == 0) return true;
        self.total_bytes = std.math.add(
            usize,
            self.total_bytes,
            chunk.len,
        ) catch return error.PayloadTooLarge;
        if (self.total_bytes > self.options.max_body_bytes) {
            return error.PayloadTooLarge;
        }
        // The source slice stays valid until the next `next` call, so a
        // partially copied chunk can be retained as `pending`.
        self.pending = chunk;
        return self.fillMore();
    }
};

/// Pulls one part's payload. Slices are valid until the next `next` call.
pub const DataReader = struct {
    stream: *Stream,
    finished: bool = false,

    /// Drain this part into an owned buffer, bounded by `max_bytes`.
    pub fn readAll(
        self: *DataReader,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) ![]u8 {
        var output = std.ArrayListUnmanaged(u8).empty;
        errdefer output.deinit(allocator);
        var total: usize = 0;
        while (try self.next()) |chunk| {
            const next_total = std.math.add(usize, total, chunk.len) catch
                return error.PayloadTooLarge;
            if (next_total > max_bytes) return error.PayloadTooLarge;
            try output.appendSlice(allocator, chunk);
            total = next_total;
        }
        return output.toOwnedSlice(allocator);
    }

    pub fn next(self: *DataReader) !?[]const u8 {
        if (self.finished) return null;
        const stream = self.stream;
        while (true) {
            const window = stream.buffer[stream.start..stream.end];
            if (findDelimiter(window, stream.next_delimiter)) |found| {
                stream.start += found + stream.next_delimiter.len;
                self.finished = true;
                if (found == 0) return null;
                return window[0..found];
            }
            const keep = stream.next_delimiter.len - 1;
            if (window.len > keep) {
                const safe = window.len - keep;
                stream.start += safe;
                return window[0..safe];
            }
            if (!try stream.fillMore()) {
                return error.InvalidMultipart;
            }
        }
    }
};

/// Find a `\r\n--boundary` occurrence followed by `-` or CRLF.
fn findDelimiter(window: []const u8, needle: []const u8) ?usize {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, window, index, needle)) |found| {
        const after = found + needle.len;
        if (after >= window.len) return found;
        if (window[after] == '\r') return found;
        if (window[after] == '-') return found;
        index = found + 1;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestSource = struct {
    body: []const u8,
    offset: usize = 0,
    chunk: usize = 7,

    fn next(raw: ?*anyopaque) anyerror!?[]const u8 {
        const self: *TestSource = @ptrCast(@alignCast(raw.?));
        if (self.offset >= self.body.len) return null;
        const end = @min(self.body.len, self.offset + self.chunk);
        const slice = self.body[self.offset..end];
        self.offset = end;
        return slice;
    }

    fn source(self: *TestSource) Source {
        return .{ .context = self, .next_fn = TestSource.next };
    }
};

fn expectStreamPartsWithWindow(
    body: []const u8,
    chunk: usize,
    window: usize,
    expected: []const [2][]const u8,
) !void {
    var source = TestSource{ .body = body, .chunk = chunk };
    var stream = try Stream.init(
        std.testing.allocator,
        source.source(),
        "multipart/form-data; boundary=weft",
        .{ .buffer_bytes = window },
    );
    defer stream.deinit();

    var seen: usize = 0;
    while (try stream.nextPart()) |part| {
        try std.testing.expect(seen < expected.len);
        try std.testing.expectEqualStrings(expected[seen][0], part.name);
        var collected: std.ArrayListUnmanaged(u8) = .empty;
        defer collected.deinit(std.testing.allocator);
        while (try part.data.next()) |chunk_bytes| {
            try collected.appendSlice(std.testing.allocator, chunk_bytes);
        }
        try std.testing.expectEqualStrings(expected[seen][1], collected.items);
        seen += 1;
    }
    try std.testing.expectEqual(expected.len, seen);
}

fn expectStreamParts(
    body: []const u8,
    chunk: usize,
    expected: []const [2][]const u8,
) !void {
    var source = TestSource{ .body = body, .chunk = chunk };
    var stream = try Stream.init(
        std.testing.allocator,
        source.source(),
        "multipart/form-data; boundary=weft",
        // The window must fit one part's header block.
        .{ .buffer_bytes = 256 },
    );
    defer stream.deinit();

    var seen: usize = 0;
    while (try stream.nextPart()) |part| {
        try std.testing.expect(seen < expected.len);
        try std.testing.expectEqualStrings(expected[seen][0], part.name);
        var collected: std.ArrayListUnmanaged(u8) = .empty;
        defer collected.deinit(std.testing.allocator);
        while (try part.data.next()) |chunk_bytes| {
            try collected.appendSlice(std.testing.allocator, chunk_bytes);
        }
        try std.testing.expectEqualStrings(expected[seen][1], collected.items);
        seen += 1;
    }
    try std.testing.expectEqual(expected.len, seen);
}

test "streaming multipart reads parts across chunk boundaries" {
    const body =
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"field\"\r\n" ++
        "\r\n" ++
        "value\r\n" ++
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "hello world\r\n" ++
        "--weft--\r\n";
    try expectStreamParts(body, 7, &.{
        .{ "field", "value" },
        .{ "file", "hello world" },
    });
    try expectStreamParts(body, 1, &.{
        .{ "field", "value" },
        .{ "file", "hello world" },
    });
    try expectStreamParts(body, 4096, &.{
        .{ "field", "value" },
        .{ "file", "hello world" },
    });
}

test "streaming multipart matches the buffered parser across chunk sizes" {
    const body =
        "preamble text\r\n" ++
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"alpha\"\r\n" ++
        "\r\n" ++
        "first-value\r\n" ++
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"beta\"; filename=\"b.bin\"\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "\r\n" ++
        "--weft-inside-data\r\n" ++
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"empty\"\r\n" ++
        "\r\n" ++
        "\r\n" ++
        "--weft--\r\n" ++
        "epilogue";

    // Differential oracle: the buffered parser defines the expected parts.
    var form = try multipart.parse(
        std.testing.allocator,
        "multipart/form-data; boundary=weft",
        body,
        .{},
    );
    defer form.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), form.parts.len);

    const expected = [_][2][]const u8{
        .{ form.parts[0].name, form.parts[0].data },
        .{ form.parts[1].name, form.parts[1].data },
        .{ form.parts[2].name, form.parts[2].data },
    };
    try std.testing.expectEqualStrings("beta", expected[1][0]);
    try std.testing.expectEqualStrings("--weft-inside-data", expected[1][1]);

    var chunk: usize = 1;
    while (chunk <= body.len + 1) : (chunk += 1) {
        try expectStreamPartsWithWindow(body, chunk, 256, &expected);
    }

    var window: usize = 128;
    while (window <= 512) : (window += 64) {
        try expectStreamPartsWithWindow(body, 3, window, &expected);
    }
}

test "streaming multipart streams data larger than the window" {
    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, 4096);
    defer allocator.free(payload);
    @memset(payload, 'z');

    const body = try std.fmt.allocPrint(
        allocator,
        "--weft\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\n" ++
            "{s}\r\n--weft--\r\n",
        .{payload},
    );
    defer allocator.free(body);

    var source = TestSource{ .body = body, .chunk = 512 };
    var stream = try Stream.init(
        allocator,
        source.source(),
        "multipart/form-data; boundary=weft",
        .{ .buffer_bytes = 128 },
    );
    defer stream.deinit();

    const part = (try stream.nextPart()) orelse
        return error.TestUnexpectedResult;
    var total: usize = 0;
    while (try part.data.next()) |chunk_bytes| total += chunk_bytes.len;
    try std.testing.expectEqual(@as(usize, 4096), total);
    try std.testing.expect((try stream.nextPart()) == null);
}

test "streaming multipart readAll enforces its own bound" {
    const allocator = std.testing.allocator;
    const body =
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"small\"\r\n" ++
        "\r\n" ++
        "tiny\r\n" ++
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"big\"\r\n" ++
        "\r\n" ++
        "0123456789\r\n" ++
        "--weft--\r\n";

    var source = TestSource{ .body = body, .chunk = 3 };
    var stream = try Stream.init(
        allocator,
        source.source(),
        "multipart/form-data; boundary=weft",
        .{ .buffer_bytes = 128 },
    );
    defer stream.deinit();

    const small = (try stream.nextPart()) orelse
        return error.TestUnexpectedResult;
    const small_bytes = try small.data.readAll(allocator, 16);
    defer allocator.free(small_bytes);
    try std.testing.expectEqualStrings("tiny", small_bytes);

    const big = (try stream.nextPart()) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectError(
        error.PayloadTooLarge,
        big.data.readAll(allocator, 4),
    );
    try std.testing.expect((try stream.nextPart()) == null);
}

test "streaming multipart rejects a missing boundary" {
    var source = TestSource{ .body = "not multipart", .chunk = 4 };
    var stream = try Stream.init(
        std.testing.allocator,
        source.source(),
        "multipart/form-data; boundary=weft",
        .{ .buffer_bytes = 64 },
    );
    defer stream.deinit();
    try std.testing.expectError(error.InvalidMultipart, stream.nextPart());
}

test "streaming multipart enforces the total body budget" {
    const body =
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"file\"\r\n" ++
        "\r\n" ++
        "abcdefghij\r\n" ++
        "--weft--\r\n";
    var source = TestSource{ .body = body, .chunk = 5 };
    var stream = try Stream.init(
        std.testing.allocator,
        source.source(),
        "multipart/form-data; boundary=weft",
        .{ .buffer_bytes = 64, .max_body_bytes = 8 },
    );
    defer stream.deinit();
    try std.testing.expectError(error.PayloadTooLarge, stream.nextPart());
}

test "streaming multipart parsing is total for arbitrary bytes" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x57ea_11);
    const random = prng.random();
    var buffer: [96]u8 = undefined;

    for (0..200) |_| {
        const length = random.intRangeAtMost(usize, 0, buffer.len);
        random.bytes(buffer[0..length]);

        var source = TestSource{
            .body = buffer[0..length],
            .chunk = random.intRangeAtMost(usize, 1, 16),
        };
        var stream = Stream.init(
            allocator,
            source.source(),
            "multipart/form-data; boundary=weft",
            .{ .buffer_bytes = 128 },
        ) catch continue;
        defer stream.deinit();

        var parts: usize = 0;
        while (stream.nextPart() catch break) |part| {
            parts += 1;
            var total: usize = 0;
            while (part.data.next() catch break) |chunk| {
                total += chunk.len;
                if (total > 4096) break;
            }
        }
        try std.testing.expect(parts <= 64);
    }
}
