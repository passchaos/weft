const std = @import("std");

/// Buffers a complete request body from a concurrent HTTP/2 or HTTP/3 stream.
/// The stream type only needs `nextBody(buffer, trailers)`.
pub fn readWholeBody(
    arena: std.mem.Allocator,
    staging: std.mem.Allocator,
    stream: anytype,
    expected_length: ?usize,
    max_body_bytes: usize,
    max_arena_bytes: usize,
) ![]const u8 {
    if (expected_length) |expected| {
        if (expected != 0) {
            if (expected > max_body_bytes or expected > max_arena_bytes) {
                return error.PayloadTooLarge;
            }
            const body = arena.alloc(u8, expected) catch
                return error.PayloadTooLarge;
            var offset: usize = 0;
            var buffer: [16 * 1024]u8 = undefined;
            while (true) {
                const count = (try stream.nextBody(&buffer, null)) orelse break;
                if (count == 0) continue;
                if (count > expected - offset) return error.PayloadTooLarge;
                @memcpy(body[offset..][0..count], buffer[0..count]);
                offset += count;
            }
            return body[0..offset];
        }
    }

    // Unknown length: stage outside the fixed arena so growth cannot leak
    // intermediate blocks, then copy the final bytes once.
    var output = std.ArrayListUnmanaged(u8).empty;
    defer output.deinit(staging);
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const count = (try stream.nextBody(&buffer, null)) orelse break;
        if (count == 0) continue;
        const total = std.math.add(usize, output.items.len, count) catch
            return error.PayloadTooLarge;
        if (total > max_body_bytes or total > max_arena_bytes) {
            return error.PayloadTooLarge;
        }
        output.appendSlice(staging, buffer[0..count]) catch
            return error.PayloadTooLarge;
    }
    return arena.dupe(u8, output.items) catch error.PayloadTooLarge;
}
