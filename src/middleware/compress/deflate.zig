const std = @import("std");
const vort = @import("vort");

const flate = std.compress.flate;

pub fn encode(
    allocator: std.mem.Allocator,
    body: []const u8,
    level: flate.Compress.Options,
) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    defer output.deinit();

    var window: [flate.max_window_len]u8 = undefined;
    var encoder = try flate.Compress.init(
        &output.writer,
        &window,
        .zlib,
        level,
    );
    try encoder.writer.writeAll(body);
    try encoder.finish();
    return output.toOwnedSlice();
}

pub fn initEncoder(
    allocator: std.mem.Allocator,
) !vort.deflate.ZlibIncrementalBestEncoder {
    return vort.deflate.ZlibIncrementalBestEncoder.initWithOptions(
        allocator,
        .{},
    );
}
