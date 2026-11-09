const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const quality_mod = @import("../quality.zig");
const vary = @import("../vary.zig");
const stream_mod = @import("../stream.zig");
const vort = @import("vort");

const flate = std.compress.flate;

/// Response compression with bounded, content-type-aware negotiation.
///
/// The middleware negotiates gzip, deflate, Brotli, and zstd from
/// `Accept-Encoding` quality values. It compresses only responses that already
/// have a complete body and are larger than `min_bytes`, and never compresses a
/// response that already selected a `Content-Encoding` or asked for
/// `no-transform`.
pub const Compress = struct {
    min_bytes: usize = 1024,
    level: flate.Compress.Options = .default,
    enable_gzip: bool = true,
    enable_deflate: bool = true,
    enable_br: bool = true,
    enable_zstd: bool = true,
    zstd_level: c_int = 3,

    pub fn handler(self: *Compress) ctx_mod.Handler {
        return ctx_mod.withContext(Compress, self, call);
    }

    fn call(self: *Compress, ctx: *ctx_mod.Ctx) anyerror!void {
        const negotiation = self.negotiate(ctx);
        try ctx.next();

        const response = &ctx.response;
        if (response.hasHeader("content-encoding")) return;
        if (noTransform(response.header("cache-control"))) return;

        if (response.stream) |body| {
            const coding = switch (negotiation) {
                .coding => |value| value,
                .identity => {
                    // `Vary` is only needed when another Accept-Encoding
                    // would select a different representation.
                    if (!compressible(response.header("content-type"))) return;
                    if (body.length) |length| {
                        if (length < self.min_bytes) return;
                    }
                    try vary.add(ctx, "Accept-Encoding");
                    return;
                },
                .not_acceptable => {
                    // Identity was explicitly refused and no coding is
                    // acceptable. A stream cannot be negotiated after the
                    // producer has been selected, so replace it with 406.
                    body.cancel();
                    response.stream = null;
                    response.reset();
                    response.setStatus(406);
                    response.text("Not Acceptable") catch {};
                    try vary.add(ctx, "Accept-Encoding");
                    return;
                },
            };
            if (!compressible(response.header("content-type"))) return;
            if (body.length) |length| {
                if (length < self.min_bytes) return;
            }
            try vary.add(ctx, "Accept-Encoding");
            switch (coding) {
                .gzip => {
                    const wrapper = ctx.arena.create(StreamCompress) catch
                        return;
                    const output_buffer = ctx.arena.alloc(
                        u8,
                        gzip_member_output_bytes,
                    ) catch return;
                    wrapper.* = .{
                        .original = body,
                        .level = self.level,
                        .max_chunk_bytes = ctx.limits.max_response_bytes,
                        .output_buffer = output_buffer,
                    };
                    response.setHeader(
                        "Content-Encoding",
                        "gzip",
                    ) catch return;
                    _ = response.removeHeader("content-length");
                    response.stream = .{
                        .context = wrapper,
                        .write_fn = StreamCompress.run,
                        .cancel_fn = StreamCompress.cancel,
                    };
                },
                .deflate, .br, .zstd => {
                    const wrapper = ctx.arena.create(
                        ContinuousStreamCompress,
                    ) catch return;
                    const output_buffer = ctx.arena.alloc(
                        u8,
                        stream_encoder_output_bytes,
                    ) catch return;
                    var encoder: ContinuousEncoder = undefined;
                    switch (coding) {
                        .deflate => encoder = .{ .deflate = vort.deflate.ZlibIncrementalBestEncoder.initWithOptions(
                            ctx.arena,
                            .{},
                        ) },
                        .br => encoder = .{ .br = vort.br.IncrementalPlannedStreamEncoder.initWithOptions(
                            ctx.arena,
                            .{},
                        ) },
                        .zstd => encoder = .{ .zstd = vort.zstd.NativeIncrementalFrameEncoder.init(
                            ctx.arena,
                            .{ .include_content_size = false },
                        ) catch return },
                        else => unreachable,
                    }
                    wrapper.* = .{
                        .original = body,
                        .encoder = encoder,
                        .output_buffer = output_buffer,
                    };
                    response.setHeader(
                        "Content-Encoding",
                        coding.headerValue(),
                    ) catch return;
                    _ = response.removeHeader("content-length");
                    response.stream = .{
                        .context = wrapper,
                        .write_fn = ContinuousStreamCompress.run,
                        .cancel_fn = ContinuousStreamCompress.cancel,
                    };
                },
            }
            return;
        }

        switch (negotiation) {
            .identity => {
                // See the streaming identity case above.
                if (response.body.len < self.min_bytes) return;
                if (!compressible(response.header("content-type"))) return;
                try vary.add(ctx, "Accept-Encoding");
                return;
            },
            .not_acceptable => {
                response.reset();
                response.setStatus(406);
                response.text("Not Acceptable") catch {};
                try vary.add(ctx, "Accept-Encoding");
                return;
            },
            .coding => |coding| {
                if (response.body.len < self.min_bytes) return;
                if (!compressible(response.header("content-type"))) return;
                try vary.add(ctx, "Accept-Encoding");

                // Compress in the server allocator and copy the final bytes
                // into the arena once, so encoder growth cannot exhaust the
                // fixed request arena for a body that fits.
                const staging = ctx.request_allocator orelse ctx.arena;
                const compressed = compressBody(
                    staging,
                    response.body,
                    coding,
                    self.level,
                    self.zstd_level,
                ) catch return;
                const body = if (ctx.request_allocator != null)
                    ctx.arena.dupe(u8, compressed) catch {
                        staging.free(compressed);
                        return;
                    }
                else
                    compressed;
                if (ctx.request_allocator != null) staging.free(compressed);
                response.setHeader(
                    "Content-Encoding",
                    coding.headerValue(),
                ) catch {
                    ctx.arena.free(body);
                    return;
                };
                response.setBody(body) catch {
                    _ = response.removeHeader("content-encoding");
                    ctx.arena.free(body);
                    return;
                };
            },
        }
    }

    fn negotiate(self: *const Compress, ctx: *const ctx_mod.Ctx) Negotiation {
        const header = ctx.header("accept-encoding") orelse return .identity;

        var gzip_quality: ?u16 = null;
        var deflate_quality: ?u16 = null;
        var br_quality: ?u16 = null;
        var zstd_quality: ?u16 = null;
        var identity_quality: ?u16 = null;
        var wildcard_quality: ?u16 = null;
        var saw_known = false;

        var parts = std.mem.splitScalar(u8, header, ',');
        while (parts.next()) |part| {
            const item = std.mem.trim(u8, part, " \t");
            if (item.len == 0) continue;
            const semicolon = std.mem.indexOfScalar(u8, item, ';');
            const coding = std.mem.trim(
                u8,
                if (semicolon) |index| item[0..index] else item,
                " \t",
            );
            const q = if (semicolon) |index|
                quality(item[index + 1 ..]) orelse 1000
            else
                1000;

            if (std.ascii.eqlIgnoreCase(coding, "gzip") or
                std.ascii.eqlIgnoreCase(coding, "x-gzip"))
            {
                gzip_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "deflate")) {
                deflate_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "br")) {
                br_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "zstd")) {
                zstd_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "identity")) {
                identity_quality = q;
            } else if (std.mem.eql(u8, coding, "*")) {
                wildcard_quality = q;
            } else {
                continue;
            }
            saw_known = true;
        }

        if (!saw_known) return .identity;

        const wildcard = wildcard_quality orelse 0;
        const gzip_q = if (self.enable_gzip)
            gzip_quality orelse wildcard
        else
            0;
        const deflate_q = if (self.enable_deflate)
            deflate_quality orelse wildcard
        else
            0;
        const br_q = if (self.enable_br)
            br_quality orelse wildcard
        else
            0;
        const zstd_q = if (self.enable_zstd)
            zstd_quality orelse wildcard
        else
            0;
        const identity_q = identity_quality orelse
            (if (wildcard_quality != null and wildcard == 0)
                @as(u16, 0)
            else
                @as(u16, 1000));

        var best: ?Coding = null;
        var best_quality: u16 = 0;
        if (br_q > 0 and br_q > best_quality) {
            best = .br;
            best_quality = br_q;
        }
        if (zstd_q > 0 and zstd_q > best_quality) {
            best = .zstd;
            best_quality = zstd_q;
        }
        if (gzip_q > 0 and gzip_q > best_quality) {
            best = .gzip;
            best_quality = gzip_q;
        }
        if (deflate_q > 0 and deflate_q > best_quality) {
            best = .deflate;
            best_quality = deflate_q;
        }
        if (best) |coding| return .{ .coding = coding };
        if (identity_q > 0) return .identity;
        return .not_acceptable;
    }
};

const Coding = enum {
    gzip,
    deflate,
    br,
    zstd,

    fn headerValue(self: Coding) []const u8 {
        return switch (self) {
            .gzip => "gzip",
            .deflate => "deflate",
            .br => "br",
            .zstd => "zstd",
        };
    }

    fn container(self: Coding) flate.Container {
        return switch (self) {
            .gzip => .gzip,
            .deflate => .zlib,
            .br, .zstd => unreachable,
        };
    }
};

const Negotiation = union(enum) {
    identity,
    not_acceptable,
    coding: Coding,
};

/// Apply default gzip/deflate/Brotli/zstd negotiation.
pub fn compress(ctx: *ctx_mod.Ctx) anyerror!void {
    var defaults = Compress{};
    return defaults.call(ctx);
}

fn compressBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    coding: Coding,
    level: flate.Compress.Options,
    zstd_level: c_int,
) ![]const u8 {
    switch (coding) {
        .gzip, .deflate => {
            var output = try std.Io.Writer.Allocating.initCapacity(
                allocator,
                64,
            );
            defer output.deinit();

            var window: [flate.max_window_len]u8 = undefined;
            var encoder = try flate.Compress.init(
                &output.writer,
                &window,
                coding.container(),
                level,
            );
            try encoder.writer.writeAll(body);
            try encoder.finish();

            return output.toOwnedSlice();
        },
        .br => return vort.br.encodePlannedStreamChunksAlloc(
            allocator,
            &.{body},
        ),
        .zstd => return vort.zstd.encodeFrameWithLevelAlloc(
            allocator,
            body,
            zstd_level,
        ),
    }
}

/// Streaming gzip wrapper. Each producer chunk becomes one or more gzip
/// members; RFC 1952 permits concatenated members, and a final empty member
/// guarantees a valid stream even when the producer writes no data.
///
/// Members are compressed into one reusable buffer, so a long stream does not
/// allocate per chunk from the request arena.
const StreamCompress = struct {
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

/// Largest producer slice compressed into one gzip member. A fixed window
/// bounds the reusable output buffer regardless of the response size.
const gzip_member_input_bytes = 16 * 1024;

/// Worst-case gzip member size for `input_len` bytes. Stored blocks add a
/// small per-block header, and fixed Huffman codes can expand literals to 9/8
/// of their size.
fn gzipMemberBound(input_len: usize) usize {
    return input_len + input_len / 8 + 128;
}

const gzip_member_output_bytes = gzipMemberBound(gzip_member_input_bytes);

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

const stream_encoder_output_bytes = 16 * 1024;

/// Continuous Brotli/zstd encoders. Unlike gzip, concatenating independent
/// members is not a valid single Content-Encoding stream, so one encoder
/// state spans the whole response.
const ContinuousEncoder = union(enum) {
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

const ContinuousStreamCompress = struct {
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

fn noTransform(cache_control: ?[]const u8) bool {
    const value = cache_control orelse return false;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, part, " \t"),
            "no-transform",
        )) return true;
    }
    return false;
}

fn quality(params: []const u8) ?u16 {
    var parts = std.mem.splitScalar(u8, params, ';');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse
            continue;
        const name = std.mem.trim(u8, trimmed[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "q")) continue;
        const value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        return quality_mod.parse(value) orelse 0;
    }
    return null;
}

test "compress quality parsing accepts OWS and rejects invalid values" {
    try std.testing.expectEqual(@as(?u16, 500), quality("q=0.5"));
    try std.testing.expectEqual(@as(?u16, 500), quality(" q = 0.5 "));
    try std.testing.expectEqual(@as(?u16, 0), quality("q=2"));
    try std.testing.expectEqual(@as(?u16, 0), quality("q=abc"));
    try std.testing.expectEqual(@as(?u16, 0), quality("q=-1"));
    try std.testing.expect(quality("foo=bar") == null);
    try std.testing.expect(quality("") == null);
}

fn compressible(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    // Event streams are incremental and latency-sensitive; compressing them
    // would also defeat per-event delivery.
    if (std.ascii.startsWithIgnoreCase(value, "text/event-stream")) return false;
    inline for (.{
        "text/",
        "application/json",
        "application/javascript",
        "application/x-javascript",
        "application/xml",
        "application/xhtml+xml",
        "image/svg+xml",
        "application/x-www-form-urlencoded",
    }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(value, prefix)) return true;
    }
    return false;
}

fn containsToken(value: []const u8, token: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, part, " \t"),
            token,
        )) return true;
    }
    return false;
}

test "compress middleware gzips an accepted response" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip, deflate",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var gzip_middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{gzip_middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "gzip",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(context.response.body.len < 4096);
    try std.testing.expectEqual(@as(u8, 0x1f), context.response.body[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), context.response.body[1]);
    try std.testing.expect(
        containsToken(context.response.header("vary").?, "accept-encoding"),
    );
}

test "compress middleware honors q=0 and small bodies" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip;q=0, identity",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var gzip_middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{gzip_middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
    try std.testing.expectEqual(@as(usize, 4096), context.response.body.len);
    // A client accepting gzip would still get a compressed representation.
    try std.testing.expect(context.response.header("vary") != null);
}

test "compress middleware omits Vary for bodies that never compress" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("tiny");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
    // Every Accept-Encoding value receives the same identity response, so the
    // field would not affect caching.
    try std.testing.expect(context.response.header("vary") == null);
}

test "compress middleware negotiates deflate when preferred" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip;q=0.5, deflate;q=1",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "deflate",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(context.response.body.len < 4096);
    try std.testing.expectEqual(@as(u8, 0x78), context.response.body[0]);
}

test "compress middleware returns 406 when identity is refused" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "identity;q=0",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqual(@as(u16, 406), context.response.status);
    try std.testing.expectEqualStrings("Not Acceptable", context.response.body);
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
}

test "compress middleware returns 406 for streamed bodies when identity is refused" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Producer = struct {
        var cancelled: bool = false;

        fn run(_: ?*anyopaque, _: *stream_mod.Writer) anyerror!void {}

        fn cancel(_: ?*anyopaque) void {
            cancelled = true;
        }
    };

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "identity;q=0",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.stream(.{
                    .write_fn = Producer.run,
                    .cancel_fn = Producer.cancel,
                    .length = 16,
                });
            }
        }.handle),
    };

    Producer.cancelled = false;
    try context.run();
    try std.testing.expect(Producer.cancelled);
    try std.testing.expectEqual(@as(u16, 406), context.response.status);
    try std.testing.expectEqualStrings("Not Acceptable", context.response.body);
    try std.testing.expect(context.response.stream == null);
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
}

fn decodeBody(
    allocator: std.mem.Allocator,
    encoding: []const u8,
    body: []const u8,
    max_output_len: usize,
) ![]const u8 {
    const headers = [_]@import("netz").http1.Header{.{
        .name = "Content-Encoding",
        .value = encoding,
    }};
    const decoded = try @import("netz").http1.content_coding.decodeHeadersAlloc(
        allocator,
        &headers,
        body,
        max_output_len,
    );
    return decoded.bytes;
}

fn expectRoundTrip(
    encoding: []const u8,
    compressed: []const u8,
    original: []const u8,
) !void {
    const decoded = try decodeBody(
        std.testing.allocator,
        encoding,
        compressed,
        original.len,
    );
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(original, decoded);
}

test "compress middleware supports brotli" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "br",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "br",
        context.response.header("content-encoding").?,
    );
    const original = try allocator.alloc(u8, 4096);
    defer allocator.free(original);
    @memset(original, 'a');
    try expectRoundTrip("br", context.response.body, original);
}

test "compress middleware supports zstd" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "zstd",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "zstd",
        context.response.header("content-encoding").?,
    );
    const original = try allocator.alloc(u8, 4096);
    defer allocator.free(original);
    @memset(original, 'a');
    try expectRoundTrip("zstd", context.response.body, original);
}

test "compress middleware wraps streamed bodies with gzip" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Producer = struct {
        var chunk: []const u8 = &.{};

        fn run(_: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
            try writer.write(chunk);
            try writer.write(chunk);
        }
    };

    const Collector = struct {
        allocator: std.mem.Allocator,
        bytes: std.ArrayListUnmanaged(u8) = .empty,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(self.allocator, data);
        }
    };

    const chunk = try allocator.alloc(u8, 2048);
    defer allocator.free(chunk);
    @memset(chunk, 'a');
    Producer.chunk = chunk;

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.setHeader("Content-Length", "4096");
                try ctx.stream(.{
                    .write_fn = Producer.run,
                    .length = 4096,
                });
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        "gzip",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(
        context.response.header("content-length") == null,
    );

    var collector = Collector{ .allocator = arena.allocator() };
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };
    if (context.response.stream) |*body| {
        try body.run(&writer);
    } else return error.TestUnexpectedResult;

    const decode_headers = [_]@import("netz").http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    const decoded = try @import("netz").http1.content_coding.decodeHeadersAlloc(
        arena.allocator(),
        &decode_headers,
        collector.bytes.items,
        4096,
    );
    try std.testing.expectEqual(@as(usize, 4096), decoded.bytes.len);
    for (decoded.bytes) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
}

fn expectStreamCoding(
    allocator: std.mem.Allocator,
    coding: []const u8,
    accept: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Producer = struct {
        var chunk: []const u8 = &.{};

        fn run(_: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
            try writer.write(chunk);
            try writer.write(chunk);
        }
    };

    const Collector = struct {
        allocator: std.mem.Allocator,
        bytes: std.ArrayListUnmanaged(u8) = .empty,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(self.allocator, data);
        }
    };

    const chunk = try allocator.alloc(u8, 2048);
    defer allocator.free(chunk);
    @memset(chunk, 'a');
    Producer.chunk = chunk;

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = accept,
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.setHeader("Content-Length", "4096");
                try ctx.stream(.{
                    .context = null,
                    .write_fn = Producer.run,
                    .length = 4096,
                });
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings(
        coding,
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(
        context.response.header("content-length") == null,
    );

    var collector = Collector{ .allocator = arena.allocator() };
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };
    if (context.response.stream) |*body| {
        try body.run(&writer);
    } else return error.TestUnexpectedResult;

    const decode_headers = [_]@import("netz").http1.Header{.{
        .name = "Content-Encoding",
        .value = coding,
    }};
    const decoded = try @import("netz").http1.content_coding.decodeHeadersAlloc(
        arena.allocator(),
        &decode_headers,
        collector.bytes.items,
        4096,
    );
    try std.testing.expectEqual(@as(usize, 4096), decoded.bytes.len);
    for (decoded.bytes) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
}

test "compress middleware bounds one streamed chunk" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Producer = struct {
        fn run(_: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
            try writer.write("0123456789abcdef");
        }
    };
    const Collector = struct {
        bytes: std.ArrayListUnmanaged(u8) = .empty,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(allocator, data);
        }
    };

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{ .max_response_bytes = 8 },
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.stream(.{ .write_fn = Producer.run });
            }
        }.handle),
    };

    try context.run();
    var collector = Collector{};
    defer collector.bytes.deinit(allocator);
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };
    try std.testing.expectError(
        error.ResponseTooLarge,
        context.response.stream.?.run(&writer),
    );
    try std.testing.expectEqual(@as(usize, 0), collector.bytes.items.len);
}

test "compress middleware wraps streamed bodies with deflate" {
    try expectStreamCoding(std.testing.allocator, "deflate", "deflate");
}

test "compress middleware wraps streamed bodies with brotli" {
    try expectStreamCoding(std.testing.allocator, "br", "br");
}

test "compress middleware wraps streamed bodies with zstd" {
    try expectStreamCoding(std.testing.allocator, "zstd", "zstd");
}

test "compress middleware honors no-transform" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 64 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = ctx_mod.Response.init(arena.allocator(), 64 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                const body = try ctx.arena.alloc(u8, 4096);
                @memset(body, 'a');
                try ctx.setHeader("Cache-Control", "no-transform");
                try ctx.text(body);
            }
        }.handle),
    };

    try context.run();
    try std.testing.expect(
        context.response.header("content-encoding") == null,
    );
    try std.testing.expectEqual(@as(usize, 4096), context.response.body.len);
}

test "compress middleware streams gzip within a small arena" {
    const allocator = std.testing.allocator;
    var arena_buffer: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    const arena = fixed.allocator();

    const Producer = struct {
        fn run(_: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
            var chunk: [1024]u8 = undefined;
            @memset(&chunk, 'a');
            var index: usize = 0;
            while (index < 256) : (index += 1) try writer.write(&chunk);
        }
    };

    const Collector = struct {
        bytes: std.ArrayListUnmanaged(u8) = .empty,

        fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(allocator, data);
        }
    };

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena,
        .limits = .{ .max_response_bytes = 512 * 1024 },
        .request = &request,
        .response = ctx_mod.Response.init(arena, 512 * 1024),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.setHeader("Content-Type", "text/plain");
                try ctx.stream(.{ .write_fn = Producer.run });
            }
        }.handle),
    };

    try context.run();
    var collector = Collector{};
    defer collector.bytes.deinit(allocator);
    var writer = stream_mod.Writer{
        .context = &collector,
        .write_fn = Collector.write,
    };
    try context.response.stream.?.run(&writer);

    const decode_headers = [_]@import("netz").http1.Header{.{
        .name = "Content-Encoding",
        .value = "gzip",
    }};
    const decoded = try @import("netz").http1.content_coding.decodeHeadersAlloc(
        allocator,
        &decode_headers,
        collector.bytes.items,
        256 * 1024,
    );
    defer allocator.free(decoded.bytes);
    try std.testing.expectEqual(@as(usize, 256 * 1024), decoded.bytes.len);
    for (decoded.bytes) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
}

test "compress middleware stages buffered growth outside a small arena" {
    const allocator = std.testing.allocator;
    var arena_buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    const arena = fixed.allocator();

    // Incompressible input keeps the compressed output near the input size.
    var body: [3000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    prng.random().bytes(&body);

    var headers = [_]@import("netz").http1.Header{.{
        .name = "Accept-Encoding",
        .value = "gzip",
    }};
    var request: @import("netz").http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var middleware = Compress{ .min_bytes = 0 };
    var context = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena,
        .request_allocator = allocator,
        .limits = .{ .max_response_bytes = 8192 },
        .request = &request,
        .response = ctx_mod.Response.init(arena, 8192),
        .middleware = &.{middleware.handler()},
        .final_handler = ctx_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };
    try context.response.setHeader("Content-Type", "text/plain");
    try context.response.setBody(&body);

    try context.run();
    try std.testing.expectEqualStrings(
        "gzip",
        context.response.header("content-encoding").?,
    );
    try std.testing.expect(context.response.body.len > 0);
}
