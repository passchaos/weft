const std = @import("std");
const vort = @import("vort");

pub fn encode(
    allocator: std.mem.Allocator,
    body: []const u8,
    level: c_int,
) ![]u8 {
    return vort.zstd.encodeFrameWithLevelAlloc(
        allocator,
        body,
        level,
    );
}

pub fn initEncoder(
    allocator: std.mem.Allocator,
) !vort.zstd.NativeIncrementalFrameEncoder {
    return vort.zstd.NativeIncrementalFrameEncoder.init(
        allocator,
        .{ .include_content_size = false },
    );
}
