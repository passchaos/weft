const std = @import("std");
const netz = @import("netz");

pub const Header = netz.http1.Header;

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    headers: []const Header,
    /// Field or file bytes. This borrows the request body.
    data: []const u8,
};

pub const Form = struct {
    parts: []const Part,

    pub fn part(self: Form, name: []const u8) ?*const Part {
        for (self.parts) |*candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }

    /// Release parser-owned names, filenames, header arrays, and the parts
    /// array. `data` remains owned by the request body.
    pub fn deinit(self: *Form, allocator: std.mem.Allocator) void {
        for (self.parts) |multipart_part| {
            allocator.free(multipart_part.name);
            if (multipart_part.filename) |filename| allocator.free(filename);
            allocator.free(multipart_part.headers);
        }
        allocator.free(self.parts);
        self.* = .{ .parts = &.{} };
    }
};

pub const ParseLimits = struct {
    max_parts: usize = 64,
    max_headers_per_part: usize = 16,
    max_header_bytes: usize = 8 * 1024,
};

/// Parse a buffered `multipart/form-data` body.
///
/// The body is already bounded by `Limits.max_body_bytes`; this parser adds
/// independent bounds for part count and per-part headers. Part data borrows
/// the body. Names, filenames, header arrays, and the parts array are owned by
/// `allocator` and released by `Form.deinit`.
pub fn parse(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    body: []const u8,
    limits: ParseLimits,
) !Form {
    const boundary = try boundaryFromContentType(allocator, content_type);
    errdefer allocator.free(boundary);

    const delimiter = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delimiter);
    const next_delimiter = try std.fmt.allocPrint(
        allocator,
        "\r\n--{s}",
        .{boundary},
    );
    defer allocator.free(next_delimiter);

    var parts = std.ArrayListUnmanaged(Part).empty;
    errdefer {
        for (parts.items) |part| {
            allocator.free(part.name);
            if (part.filename) |filename| allocator.free(filename);
            allocator.free(part.headers);
        }
        parts.deinit(allocator);
    }

    // Only accept a boundary at the start of the body or after a CRLF, so
    // field data containing the boundary text is not mistaken for a delimiter.
    var cursor: usize = 0;
    if (std.mem.startsWith(u8, body, delimiter) and
        body.len > delimiter.len and
        (body[delimiter.len] == '\r' or
            (body[delimiter.len] == '-' and
                delimiter.len + 1 < body.len and
                body[delimiter.len + 1] == '-')))
    {
        cursor = delimiter.len;
    } else if (findDelimiter(body, 0, next_delimiter)) |found| {
        cursor = found + next_delimiter.len;
    } else {
        return error.InvalidMultipart;
    }

    while (true) {
        if (cursor >= body.len) return error.InvalidMultipart;
        if (body[cursor] == '-') {
            if (cursor + 1 < body.len and body[cursor + 1] == '-') break;
            return error.InvalidMultipart;
        }
        if (body[cursor] != '\r' or
            cursor + 1 >= body.len or
            body[cursor + 1] != '\n')
        {
            return error.InvalidMultipart;
        }
        cursor += 2;

        const next = findDelimiter(body, cursor, next_delimiter) orelse
            return error.InvalidMultipart;
        const segment = body[cursor..next];
        cursor = next + next_delimiter.len;

        const separator = std.mem.indexOf(u8, segment, "\r\n\r\n") orelse
            return error.InvalidMultipart;
        const header_block = segment[0..separator];
        const data = segment[separator + 4 ..];

        var headers = std.ArrayListUnmanaged(Header).empty;
        errdefer headers.deinit(allocator);

        var name: ?[]const u8 = null;
        errdefer if (name) |value| allocator.free(value);
        var filename: ?[]const u8 = null;
        errdefer if (filename) |value| allocator.free(value);
        var content_type_value: ?[]const u8 = null;
        var header_bytes: usize = 0;

        var lines = std.mem.splitSequence(u8, header_block, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            header_bytes = std.math.add(
                usize,
                header_bytes,
                line.len + 2,
            ) catch return error.InvalidMultipart;
            if (header_bytes > limits.max_header_bytes) {
                return error.InvalidMultipart;
            }
            if (headers.items.len >= limits.max_headers_per_part) {
                return error.InvalidMultipart;
            }

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse
                return error.InvalidMultipart;
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            try headers.append(allocator, .{
                .name = header_name,
                .value = header_value,
            });

            if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
                try parseDisposition(
                    allocator,
                    header_value,
                    &name,
                    &filename,
                );
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
                content_type_value = header_value;
            }
        }

        const field_name = name orelse return error.InvalidMultipart;
        if (field_name.len == 0) return error.InvalidMultipart;
        if (parts.items.len >= limits.max_parts) {
            return error.TooManyParts;
        }
        const header_slice = try headers.toOwnedSlice(allocator);
        errdefer allocator.free(header_slice);
        try parts.append(allocator, .{
            .name = field_name,
            .filename = filename,
            .content_type = content_type_value,
            .headers = header_slice,
            .data = data,
        });
    }

    if (parts.items.len == 0) return error.InvalidMultipart;
    return .{ .parts = try parts.toOwnedSlice(allocator) };
}

/// Find a `\r\n--boundary` occurrence whose boundary is followed by either
/// `-` (close delimiter) or CRLF (next part).
fn findDelimiter(
    body: []const u8,
    from: usize,
    needle: []const u8,
) ?usize {
    var index = from;
    while (std.mem.indexOfPos(u8, body, index, needle)) |found| {
        const after = found + needle.len;
        if (after < body.len) {
            if (body[after] == '\r') return found;
            if (body[after] == '-' and
                after + 1 < body.len and
                body[after + 1] == '-')
            {
                return found;
            }
        }
        index = found + 1;
    }
    return null;
}

fn boundaryFromContentType(
    allocator: std.mem.Allocator,
    content_type: []const u8,
) ![]const u8 {
    const media_type = "multipart/form-data";
    if (!std.ascii.startsWithIgnoreCase(content_type, media_type)) {
        return error.NotMultipart;
    }
    if (content_type.len > media_type.len) {
        const delimiter = content_type[media_type.len];
        if (delimiter != ';' and delimiter != ' ' and delimiter != '\t') {
            return error.NotMultipart;
        }
    }

    var params = std.mem.splitScalar(
        u8,
        content_type[media_type.len..],
        ';',
    );
    while (params.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        if (!std.ascii.startsWithIgnoreCase(param, "boundary=")) continue;
        const boundary = try parseQuoted(
            allocator,
            param["boundary=".len..],
        );
        errdefer allocator.free(boundary);
        if (boundary.len == 0 or boundary.len > 70) {
            return error.InvalidMultipart;
        }
        for (boundary) |char| {
            if (char < 0x20 or char == 0x7f) {
                return error.InvalidMultipart;
            }
        }
        return boundary;
    }
    return error.MissingBoundary;
}

fn parseDisposition(
    allocator: std.mem.Allocator,
    value: []const u8,
    name: *?[]const u8,
    filename: *?[]const u8,
) !void {
    const disposition = "form-data";
    if (!std.ascii.startsWithIgnoreCase(value, disposition)) {
        return error.InvalidMultipart;
    }
    if (value.len > disposition.len) {
        const delimiter = value[disposition.len];
        if (delimiter != ';' and delimiter != ' ' and delimiter != '\t') {
            return error.InvalidMultipart;
        }
    }

    var params = std.mem.splitScalar(u8, value[disposition.len..], ';');
    while (params.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        if (std.ascii.startsWithIgnoreCase(param, "name=")) {
            if (name.* != null) return error.InvalidMultipart;
            name.* = try parseQuoted(allocator, param["name=".len..]);
        } else if (std.ascii.startsWithIgnoreCase(param, "filename=")) {
            if (filename.* != null) return error.InvalidMultipart;
            filename.* = try parseQuoted(
                allocator,
                param["filename=".len..],
            );
        }
    }
}

fn parseQuoted(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]const u8 {
    const value = std.mem.trim(u8, text, " \t");
    if (value.len == 0) return error.InvalidMultipart;
    if (value[0] != '"') return allocator.dupe(u8, value);

    var output = std.ArrayListUnmanaged(u8).empty;
    errdefer output.deinit(allocator);

    var index: usize = 1;
    while (index < value.len) {
        const char = value[index];
        if (char == '"') {
            return output.toOwnedSlice(allocator);
        }
        if (char == '\\' and index + 1 < value.len) {
            index += 1;
            try output.append(allocator, value[index]);
            index += 1;
            continue;
        }
        try output.append(allocator, char);
        index += 1;
    }
    return error.InvalidMultipart;
}

test "multipart parses fields and files" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const body =
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"field\"\r\n" ++
        "\r\n" ++
        "value\r\n" ++
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "hello\r\n" ++
        "--weft--\r\n";

    var form = try parse(
        arena.allocator(),
        "multipart/form-data; boundary=weft",
        body,
        .{},
    );
    defer form.deinit(arena.allocator());

    try std.testing.expectEqual(@as(usize, 2), form.parts.len);
    const field = form.part("field").?;
    try std.testing.expectEqualStrings("value", field.data);
    try std.testing.expect(field.filename == null);

    const file = form.part("file").?;
    try std.testing.expectEqualStrings("hello", file.data);
    try std.testing.expectEqualStrings("a.txt", file.filename.?);
    try std.testing.expectEqualStrings("text/plain", file.content_type.?);
}

test "multipart ignores boundary text inside part data" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const body =
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"field\"\r\n" ++
        "\r\n" ++
        "--weft-not-a-boundary\r\n" ++
        "--weft--\r\n";

    var form = try parse(
        arena.allocator(),
        "multipart/form-data; boundary=weft",
        body,
        .{},
    );
    defer form.deinit(arena.allocator());

    const field = form.part("field").?;
    try std.testing.expectEqualStrings("--weft-not-a-boundary", field.data);
}

test "multipart accepts a preamble before the first boundary" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const body =
        "ignored preamble\r\n" ++
        "--weft\r\n" ++
        "Content-Disposition: form-data; name=\"field\"\r\n" ++
        "\r\n" ++
        "value\r\n" ++
        "--weft--\r\n";

    var form = try parse(
        arena.allocator(),
        "multipart/form-data; boundary=weft",
        body,
        .{},
    );
    defer form.deinit(arena.allocator());

    try std.testing.expectEqualStrings("value", form.part("field").?.data);
}

test "multipart rejects missing boundaries and malformed parts" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.MissingBoundary,
        parse(
            arena.allocator(),
            "multipart/form-data",
            "body",
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidMultipart,
        parse(
            arena.allocator(),
            "multipart/form-data; boundary=weft",
            "--weft\r\nContent-Type: text/plain\r\n\r\nx\r\n--weft--\r\n",
            .{},
        ),
    );
    try std.testing.expectError(
        error.TooManyParts,
        parse(
            arena.allocator(),
            "multipart/form-data; boundary=weft",
            "--weft\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" ++
                "--weft\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n" ++
                "--weft--\r\n",
            .{ .max_parts = 1 },
        ),
    );
}
