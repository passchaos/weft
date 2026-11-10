const std = @import("std");
const stream_mod = @import("../../stream.zig");
const vort = @import("vort");
const negotiate = @import("negotiate.zig");
const brotli = @import("brotli.zig");
const deflate = @import("deflate.zig");
const zstd = @import("zstd.zig");

pub const stream_encoder_output_bytes = 16 * 1024;

/// Continuous deflate/Brotli/zstd encoders. Unlike gzip, concatenating
/// independent members is not a valid single Content-Encoding stream, so one
/// encoder state spans the whole response.
pub const ContinuousEncoder = union(enum) {
    deflate: vort.deflate.ZlibIncrementalBestEncoder,
    br: vort.br.IncrementalPlannedStreamEncoder,
    zstd: vort.zstd.NativeIncrementalFrameEncoder,

    fn step(
        self: *ContinuousEncoder,
        input: []const u8,
        output: []u8,
    ) anyerror!vort.core.StepResult {
        return switch (self.*) {
            .deflate => |*state| state.step(input, output),
            .br => |*state| state.step(input, output),
            .zstd => |*state| state.step(input, output),
        };
    }

    fn finish(self: *ContinuousEncoder) anyerror!void {
        switch (self.*) {
            .deflate => |*state| state.finish(),
            .br => |*state| try state.finish(),
            .zstd => |*state| state.finish(),
        }
    }
};

pub const ContinuousStreamCompress = struct {
    original: stream_mod.Body,
    encoder: ContinuousEncoder,
    output_buffer: []u8,

    fn run(raw: ?*anyopaque, output: *stream_mod.Writer) anyerror!void {
        const self: *ContinuousStreamCompress = @ptrCast(@alignCast(raw orelse
            return error.InvalidWriterState));
        var chunk = ContinuousChunk{
            .wrapper = self,
            .output = output,
        };
        var writer = stream_mod.Writer{
            .context = &chunk,
            .write_fn = ContinuousChunk.writeChunk,
        };
        try self.original.run(&writer);
        try self.finishTo(output);
    }

    fn finishTo(
        self: *ContinuousStreamCompress,
        output: *stream_mod.Writer,
    ) !void {
        try self.encoder.finish();
        while (true) {
            const result = try self.encoder.step(
                &.{},
                self.output_buffer,
            );
            if (result.progress.output_written != 0) {
                try output.write(
                    self.output_buffer[0..result.progress.output_written],
                );
            }
            switch (result.status) {
                .done => return,
                .need_output => {
                    if (result.progress.output_written == 0) {
                        return error.CompressionStalled;
                    }
                },
                .need_input => return error.CompressionStalled,
            }
        }
    }

    fn cancel(raw: ?*anyopaque) void {
        const self: *ContinuousStreamCompress = @ptrCast(@alignCast(raw orelse
            return));
        self.original.cancel();
    }
};

pub fn wrap(
    arena: std.mem.Allocator,
    body: stream_mod.Body,
    coding: negotiate.Coding,
) !stream_mod.Body {
    const wrapper = try arena.create(ContinuousStreamCompress);
    const output_buffer = try arena.alloc(u8, stream_encoder_output_bytes);
    const encoder: ContinuousEncoder = switch (coding) {
        .deflate => .{ .deflate = try deflate.initEncoder(arena) },
        .br => .{ .br = try brotli.initEncoder(arena) },
        .zstd => .{ .zstd = try zstd.initEncoder(arena) },
        .gzip => unreachable,
    };
    wrapper.* = .{
        .original = body,
        .encoder = encoder,
        .output_buffer = output_buffer,
    };
    return .{
        .context = wrapper,
        .write_fn = ContinuousStreamCompress.run,
        .cancel_fn = ContinuousStreamCompress.cancel,
    };
}

const ContinuousChunk = struct {
    wrapper: *ContinuousStreamCompress,
    output: *stream_mod.Writer,

    fn writeChunk(raw: ?*anyopaque, data: []const u8) anyerror!void {
        const self: *ContinuousChunk = @ptrCast(@alignCast(raw orelse
            return error.InvalidWriterState));
        var offset: usize = 0;
        while (true) {
            const result = try self.wrapper.encoder.step(
                data[offset..],
                self.wrapper.output_buffer,
            );
            const written = result.progress.output_written;
            if (written != 0) {
                try self.output.write(
                    self.wrapper.output_buffer[0..written],
                );
            }
            offset += result.progress.input_read;
            switch (result.status) {
                .need_input => {
                    if (offset == data.len) return;
                    if (result.progress.input_read == 0) {
                        return error.CompressionStalled;
                    }
                },
                .need_output => {
                    if (written == 0) return error.CompressionStalled;
                },
                .done => {
                    if (offset != data.len) {
                        return error.CompressionStalled;
                    }
                    return;
                },
            }
        }
    }
};
