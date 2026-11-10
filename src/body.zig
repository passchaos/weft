const std = @import("std");
const netz = @import("netz");

/// One-chunk reader for adapters that already buffered the request body.
pub const ReplayReader = struct {
    body: []const u8,
    consumed: bool = false,

    pub fn next(self: *ReplayReader) !?[]const u8 {
        if (self.consumed) return null;
        self.consumed = true;
        return self.body;
    }
};

/// Stack copy window used by the HTTP/2 and HTTP/3 streaming readers. The
/// configured `max_streaming_window_bytes` may lower it, but not raise it.
pub const stream_reader_buffer_bytes = 16 * 1024;

/// Pull reader over an HTTP/2 concurrent stream.
pub const H2StreamReader = struct {
    stream: *netz.http2.runtime.Connection.ConcurrentStream,
    buffer: [stream_reader_buffer_bytes]u8 = undefined,
    window: usize = stream_reader_buffer_bytes,

    pub fn init(
        stream: *netz.http2.runtime.Connection.ConcurrentStream,
        max_window: usize,
    ) H2StreamReader {
        return .{
            .stream = stream,
            .window = @max(1, @min(max_window, stream_reader_buffer_bytes)),
        };
    }

    pub fn next(self: *H2StreamReader) !?[]const u8 {
        while (true) {
            const count = (try self.stream.nextBody(
                self.buffer[0..self.window],
                null,
            )) orelse return null;
            if (count != 0) return self.buffer[0..count];
        }
    }
};

pub const H3StreamReader = struct {
    stream: *netz.http3.runtime.HandshakeServerSession.ConcurrentStream,
    buffer: [stream_reader_buffer_bytes]u8 = undefined,
    window: usize = stream_reader_buffer_bytes,

    pub fn init(
        stream: *netz.http3.runtime.HandshakeServerSession.ConcurrentStream,
        max_window: usize,
    ) H3StreamReader {
        return .{
            .stream = stream,
            .window = @max(1, @min(max_window, stream_reader_buffer_bytes)),
        };
    }

    pub fn next(self: *H3StreamReader) !?[]const u8 {
        while (true) {
            const count = (try self.stream.nextBody(
                self.buffer[0..self.window],
                null,
            )) orelse return null;
            if (count != 0) return self.buffer[0..count];
        }
    }
};

/// Per-route body budget wrapper. Returns `error.PayloadTooLarge` before
/// handing out a chunk that would exceed the route's limit.
pub const LimitedReader = struct {
    inner: BodyReader,
    remaining: usize,

    pub fn next(self: *LimitedReader) !?[]const u8 {
        const chunk = (try self.inner.next()) orelse return null;
        if (chunk.len > self.remaining) return error.PayloadTooLarge;
        self.remaining -= chunk.len;
        return chunk;
    }
};

/// Incremental `Content-Encoding` decoder over a streaming body reader.
/// Encoded bytes are bounded by `max_body_bytes` and decoded output by the
/// same budget, so large compressed uploads never need whole-body buffering.
pub const DecodedReader = struct {
    inner: BodyReader,
    decoder: netz.http.content_coding.StreamDecoder,
    output: []u8,
    pending: []const u8 = &.{},
    inner_done: bool = false,
    finished: bool = false,
    max_decoded: usize,
    decoded_total: usize = 0,

    pub fn next(self: *DecodedReader) !?[]const u8 {
        while (!self.finished) {
            if (!self.inner_done and self.pending.len == 0) {
                if (try self.inner.next()) |chunk| {
                    self.pending = chunk;
                } else {
                    self.inner_done = true;
                }
            }
            if (self.pending.len != 0) {
                const result = self.decoder.step(
                    self.pending,
                    self.output,
                ) catch return error.InvalidContentEncoding;
                self.pending = self.pending[result.input_read..];
                if (result.output_written != 0) {
                    return try self.commit(result.output_written);
                }
                continue;
            }
            const result = self.decoder.finish(self.output) catch
                return error.InvalidContentEncoding;
            if (result.output_written != 0) {
                return try self.commit(result.output_written);
            }
            if (result.status == .done) {
                self.finished = true;
                return null;
            }
            return error.InvalidContentEncoding;
        }
        return null;
    }

    fn commit(self: *DecodedReader, count: usize) ![]const u8 {
        const next_total = std.math.add(
            usize,
            self.decoded_total,
            count,
        ) catch return error.PayloadTooLarge;
        if (next_total > self.max_decoded) return error.PayloadTooLarge;
        self.decoded_total = next_total;
        return self.output[0..count];
    }
};

/// Incremental request-body source. HTTP/1 uses netz's pull reader, HTTP/2
/// pulls from a duplex/concurrent stream, and HTTP/3 pulls from the concurrent
/// stream engine (or replays a buffered body on the legacy adapter).
pub const BodyReader = union(enum) {
    pull: *netz.http1.runtime.RequestBodyReader,
    duplex: *netz.http2.runtime.ServerDuplexStream,
    h2_stream: *H2StreamReader,
    h3_stream: *H3StreamReader,
    replay: *ReplayReader,
    limited: *LimitedReader,
    decoded: *DecodedReader,

    pub fn next(self: BodyReader) !?[]const u8 {
        return switch (self) {
            .pull => |reader| reader.next(),
            .duplex => |stream| stream.nextBody(),
            .h2_stream => |reader| reader.next(),
            .h3_stream => |reader| reader.next(),
            .replay => |reader| reader.next(),
            .limited => |reader| reader.next(),
            .decoded => |reader| reader.next(),
        };
    }
};
