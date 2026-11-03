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

/// Write one event terminated by a blank line.
///
/// `id` and `event` must not contain CR, LF, or NUL. Data lines have a trailing
/// CR removed so CRLF input renders correctly.
pub fn write(writer: *stream_mod.Writer, event: Event) !void {
    if (event.id) |id| {
        try validateField(id);
        try writer.write("id: ");
        try writer.write(id);
        try writer.write("\n");
    }
    if (event.event) |name| {
        try validateField(name);
        try writer.write("event: ");
        try writer.write(name);
        try writer.write("\n");
    }
    if (event.retry) |milliseconds| {
        var buffer: [24]u8 = undefined;
        const value = try std.fmt.bufPrint(
            &buffer,
            "retry: {d}\n",
            .{milliseconds},
        );
        try writer.write(value);
    }

    var lines = std.mem.splitScalar(u8, event.data, '\n');
    while (lines.next()) |raw_line| {
        const line = if (raw_line.len > 0 and
            raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        try validateField(line);
        try writer.write("data: ");
        try writer.write(line);
        try writer.write("\n");
    }
    try writer.write("\n");
}

/// Write a comment line, commonly used as a keep-alive heartbeat.
pub fn comment(writer: *stream_mod.Writer, text: []const u8) !void {
    try validateField(text);
    try writer.write(": ");
    try writer.write(text);
    try writer.write("\n\n");
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

    try comment(&writer, "keep-alive");
    try std.testing.expectEqualStrings(
        ": keep-alive\n\n",
        collector.bytes.items[collector.bytes.items.len - ": keep-alive\n\n".len ..],
    );
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
