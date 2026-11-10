const std = @import("std");
const stream_mod = @import("../multipart_stream.zig");
const delimiter = @import("delimiter.zig");

/// Pulls one part's payload. Slices are valid until the next `next` call.
pub const DataReader = struct {
    stream: *stream_mod.Stream,
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
            const window = stream.bufferedWindow();
            switch (delimiter.findDelimiter(window, stream.nextDelimiter())) {
                .found => |found| {
                    stream.advance(found + stream.nextDelimiter().len);
                    self.finished = true;
                    if (found == 0) return null;
                    return window[0..found];
                },
                .incomplete => |found| {
                    // The candidate ends at the window boundary, so the bytes
                    // that decide whether this is a delimiter line are not
                    // buffered yet. Return the safe prefix and keep the
                    // candidate in place for the next fill.
                    if (found != 0) {
                        stream.advance(found);
                        return window[0..found];
                    }
                    if (!try stream.fill()) {
                        return error.InvalidMultipart;
                    }
                    continue;
                },
                .none => {},
            }
            const keep = stream.nextDelimiter().len - 1;
            if (window.len > keep) {
                const safe = window.len - keep;
                stream.advance(safe);
                return window[0..safe];
            }
            if (!try stream.fill()) {
                return error.InvalidMultipart;
            }
        }
    }
};
