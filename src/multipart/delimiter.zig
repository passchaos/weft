const std = @import("std");

pub const DelimiterMatch = union(enum) {
    none,
    /// The needle is present at this index, but the bytes that decide whether
    /// it starts a delimiter line are not buffered yet.
    incomplete: usize,
    /// A complete delimiter line starts at this index.
    found: usize,
};

/// Find a `\r\n--boundary` occurrence that starts a delimiter line. The
/// boundary must be followed by the closing `--` or by a complete CRLF; a bare
/// CR or a single `-` is payload text, not a delimiter.
pub fn findDelimiter(window: []const u8, needle: []const u8) DelimiterMatch {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, window, index, needle)) |found| {
        const after = found + needle.len;
        if (after >= window.len) return .{ .incomplete = found };
        if (window[after] == '-') {
            if (after + 1 >= window.len) return .{ .incomplete = found };
            if (window[after + 1] == '-') return .{ .found = found };
        } else if (window[after] == '\r') {
            if (after + 1 >= window.len) return .{ .incomplete = found };
            if (window[after + 1] == '\n') return .{ .found = found };
        }
        index = found + 1;
    }
    return .none;
}
