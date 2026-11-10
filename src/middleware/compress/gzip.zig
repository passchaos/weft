const std = @import("std");
const stream_mod = @import("../../stream.zig");

const flate = std.compress.flate;

/// Largest producer slice compressed into one gzip member. A fixed window
/// bounds the reusable output buffer regardless of the response size.
pub const gzip_member_input_bytes = 16 * 1024;

/// Worst-case gzip member size for `input_len` bytes. Stored blocks add a
/// small per-block header, and fixed Huffman codes can expand literals to 9/8
/// of their size.
pub fn gzipMemberBound(input_len: usize) usize {
    return input_len + input_len / 8 + 128;
}

pub const gzip_member_output_bytes = gzipMemberBound(gzip_member_input_bytes);

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
        .gzip,
        level,
    );
    try encoder.writer.writeAll(body);
    try encoder.finish();
    return output.toOwnedSlice();
}

fn compressGzipMember(
    buffer: []u8,
    output: *stream_mod.Writer,
    data: []const u8,
    level: flate.Compress.Options,
) !void {
    var writer = std.Io.Writer.fixed(buffer);
    var window: [flate.max_window_len]u8 = undefined;
    var encoder = try flate.Compress.init(
        &writer,
        &window,
        .gzip,
        level,
    );
    try encoder.writer.writeAll(data);
    try encoder.finish();
    try output.write(writer.buffered());
}

/// Streaming gzip wrapper. Each producer chunk becomes one or more gzip
/// members; RFC 1952 permits concatenated members, and a final empty member
/// guarantees a valid stream even when the producer writes no data.
///
/// Members are compressed into one reusable buffer, so a long stream does not
/// allocate per chunk from the request arena.
pub const StreamCompress = struct {
    original: stream_mod.Body,
    level: flate.Compress.Options,
    /// Bound for one producer chunk; the transport writer enforces the total
    /// response budget.
    max_chunk_bytes: usize,
    output_buffer: []u8,

    fn run(raw: ?*anyopaque, output: *stream_mod.Writer) anyerror!void {
        const self: *StreamCompress = @ptrCast(@alignCast(raw orelse
            return error.InvalidWriterState));
        var chunk = ChunkCompress{
            .output = output,
            .level = self.level,
            .max_chunk_bytes = self.max_chunk_bytes,
            .output_buffer = self.output_buffer,
        };
        var writer = stream_mod.Writer{
            .context = &chunk,
            .write_fn = ChunkCompress.writeChunk,
        };
        try self.original.run(&writer);
        try ChunkCompress.writeChunk(&chunk, "");
    }

    fn cancel(raw: ?*anyopaque) void {
        const self: *StreamCompress = @ptrCast(@alignCast(raw orelse return));
        self.original.cancel();
    }
};

pub fn wrap(
    arena: std.mem.Allocator,
    body: stream_mod.Body,
    level: flate.Compress.Options,
    max_chunk_bytes: usize,
) !stream_mod.Body {
    const wrapper = try arena.create(StreamCompress);
    const output_buffer = try arena.alloc(u8, gzip_member_output_bytes);
    wrapper.* = .{
        .original = body,
        .level = level,
        .max_chunk_bytes = max_chunk_bytes,
        .output_buffer = output_buffer,
    };
    return .{
        .context = wrapper,
        .write_fn = StreamCompress.run,
        .cancel_fn = StreamCompress.cancel,
    };
}

const ChunkCompress = struct {
    output: *stream_mod.Writer,
    level: flate.Compress.Options,
    max_chunk_bytes: usize,
    output_buffer: []u8,

    fn writeChunk(raw: ?*anyopaque, data: []const u8) anyerror!void {
        const self: *ChunkCompress = @ptrCast(@alignCast(raw orelse
            return error.InvalidWriterState));
        if (data.len > self.max_chunk_bytes) return error.ResponseTooLarge;
        if (data.len == 0) {
            try compressGzipMember(
                self.output_buffer,
                self.output,
                &.{},
                self.level,
            );
            return;
        }
        var offset: usize = 0;
        while (offset < data.len) {
            const end = @min(data.len, offset + gzip_member_input_bytes);
            try compressGzipMember(
                self.output_buffer,
                self.output,
                data[offset..end],
                self.level,
            );
            offset = end;
        }
    }
};
