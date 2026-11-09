const std = @import("std");
const stream_mod = @import("stream.zig");

/// One server-sent event. Fields are emitted only when present.
pub const Event = struct {
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
    /// Reconnection delay in milliseconds.
    retry: ?u32 = null,
    /// Payload. Newlines become multiple `data:` lines.
    data: []const u8 = "",
};

/// Bytes formatted into one stack buffer before falling back to per-field
/// writes. Batching avoids one transport write per SSE field.
const batch_bytes = 512;

/// Write one event terminated by a blank line.
///
/// `id` and `event` must not contain CR, LF, or NUL. Data lines have a trailing
/// CR removed so CRLF input renders correctly.
pub fn write(writer: *stream_mod.Writer, event: Event) !void {
    var buffer: [batch_bytes]u8 = undefined;
    var batch = std.Io.Writer.fixed(&buffer);
    formatEvent(&batch, event) catch {
        // Too large for the stack buffer, or invalid. Stream the fields so
        // the error and partial-output behavior match the unbatched path.
        return formatEvent(writer, event);
    };
    try writer.write(batch.buffered());
}

/// Write a comment line, commonly used as a keep-alive heartbeat.
pub fn comment(writer: *stream_mod.Writer, text: []const u8) !void {
    try validateField(text);
    var buffer: [batch_bytes]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, ": {s}\n\n", .{text}) catch {
        try writer.write(": ");
        try writer.write(text);
        return writer.write("\n\n");
    };
    try writer.write(value);
}

fn formatEvent(writer: anytype, event: Event) !void {
    if (event.id) |id| {
        try validateField(id);
        try put(writer, "id: ");
        try put(writer, id);
        try put(writer, "\n");
    }
    if (event.event) |name| {
        try validateField(name);
        try put(writer, "event: ");
        try put(writer, name);
        try put(writer, "\n");
    }
    if (event.retry) |milliseconds| {
        var buffer: [24]u8 = undefined;
        const value = try std.fmt.bufPrint(
            &buffer,
            "retry: {d}\n",
            .{milliseconds},
        );
        try put(writer, value);
    }

    var lines = std.mem.splitScalar(u8, event.data, '\n');
    while (lines.next()) |raw_line| {
        const line = if (raw_line.len > 0 and
            raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        try validateField(line);
        try put(writer, "data: ");
        try put(writer, line);
        try put(writer, "\n");
    }
    try put(writer, "\n");
}

/// Write all bytes to either a `std.Io.Writer` (which may accept a partial
/// slice) or the concrete stream writer (which accepts the whole slice).
fn put(writer: anytype, bytes: []const u8) !void {
    if (@TypeOf(writer) == *std.Io.Writer) {
        try writer.writeAll(bytes);
    } else {
        try writer.write(bytes);
    }
}

fn validateField(value: []const u8) !void {
    for (value) |char| {
        if (char == '\r' or char == '\n' or char == 0) {
            return error.InvalidSseField;
        }
    }
}

test "sse formats fields and splits multiline data" {
    const allocator = std.testing.allocator;

    const Collector = struct {
        bytes: std.ArrayListUnmanaged(u8) = .empty,
        writes: usize = 0,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.writes += 1;
            try self.bytes.appendSlice(allocator, data);
        }
    };

    var collector = Collector{};
    defer collector.bytes.deinit(allocator);
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };

    try write(&writer, .{
        .id = "42",
        .event = "update",
        .retry = 1500,
        .data = "first\r\nsecond",
    });
    try std.testing.expectEqualStrings(
        "id: 42\nevent: update\nretry: 1500\ndata: first\ndata: second\n\n",
        collector.bytes.items,
    );
    // The whole event fits the batch buffer and reaches the transport once.
    try std.testing.expectEqual(@as(usize, 1), collector.writes);

    try comment(&writer, "keep-alive");
    try std.testing.expectEqual(@as(usize, 2), collector.writes);
    try std.testing.expectEqualStrings(
        ": keep-alive\n\n",
        collector.bytes.items[collector.bytes.items.len - ": keep-alive\n\n".len ..],
    );
}

test "sse streams events larger than the batch buffer" {
    const allocator = std.testing.allocator;
    const payload = "a" ** 600;

    const Collector = struct {
        bytes: std.ArrayListUnmanaged(u8) = .empty,
        writes: usize = 0,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.writes += 1;
            try self.bytes.appendSlice(allocator, data);
        }
    };

    var collector = Collector{};
    defer collector.bytes.deinit(allocator);
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };

    try write(&writer, .{ .data = payload });
    try std.testing.expectEqualStrings(
        "data: " ++ payload ++ "\n\n",
        collector.bytes.items,
    );
    try std.testing.expect(collector.writes > 1);
}

test "sse rejects header injection" {
    const allocator = std.testing.allocator;

    const Collector = struct {
        bytes: std.ArrayListUnmanaged(u8) = .empty,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(allocator, data);
        }
    };

    var collector = Collector{};
    defer collector.bytes.deinit(allocator);
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };

    try std.testing.expectError(
        error.InvalidSseField,
        write(&writer, .{ .event = "bad\nname", .data = "x" }),
    );
    try std.testing.expectError(
        error.InvalidSseField,
        write(&writer, .{ .id = "bad\rname", .data = "x" }),
    );
    try std.testing.expectError(
        error.InvalidSseField,
        comment(&writer, "bad\ntext"),
    );
}
