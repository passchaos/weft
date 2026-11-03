const std = @import("std");
const ctx_mod = @import("ctx.zig");
const precondition = @import("precondition.zig");
const stream_mod = @import("stream.zig");

pub const MimeType = struct {
    extension: []const u8,
    content_type: []const u8,
};

pub const default_mime_types = [_]MimeType{
    .{ .extension = ".html", .content_type = "text/html; charset=utf-8" },
    .{ .extension = ".htm", .content_type = "text/html; charset=utf-8" },
    .{ .extension = ".css", .content_type = "text/css; charset=utf-8" },
    .{ .extension = ".js", .content_type = "text/javascript; charset=utf-8" },
    .{ .extension = ".mjs", .content_type = "text/javascript; charset=utf-8" },
    .{ .extension = ".json", .content_type = "application/json" },
    .{ .extension = ".map", .content_type = "application/json" },
    .{ .extension = ".txt", .content_type = "text/plain; charset=utf-8" },
    .{ .extension = ".xml", .content_type = "application/xml" },
    .{ .extension = ".svg", .content_type = "image/svg+xml" },
    .{ .extension = ".png", .content_type = "image/png" },
    .{ .extension = ".jpg", .content_type = "image/jpeg" },
    .{ .extension = ".jpeg", .content_type = "image/jpeg" },
    .{ .extension = ".gif", .content_type = "image/gif" },
    .{ .extension = ".webp", .content_type = "image/webp" },
    .{ .extension = ".avif", .content_type = "image/avif" },
    .{ .extension = ".ico", .content_type = "image/x-icon" },
    .{ .extension = ".woff", .content_type = "font/woff" },
    .{ .extension = ".woff2", .content_type = "font/woff2" },
    .{ .extension = ".ttf", .content_type = "font/ttf" },
    .{ .extension = ".otf", .content_type = "font/otf" },
    .{ .extension = ".pdf", .content_type = "application/pdf" },
    .{ .extension = ".wasm", .content_type = "application/wasm" },
};

pub const default_cache_control = "public, max-age=3600";
pub const max_segments = 128;

/// Serve files below `dir` through a route such as `/assets/*`.
///
/// The handler reads `ctx.param("*")`, normalizes the relative path, rejects
/// traversal and dotfiles, and streams the file through `Ctx.stream`. Files
/// larger than `max_file_bytes` or `Limits.max_response_bytes` are rejected.
/// The caller owns `dir` and must close it after the router and server stop
/// using this handler.
///
/// When `precompressed` is enabled, `.br`, `.zst`, and `.gz` sidecars are
/// served for clients that accept them, and `Vary: Accept-Encoding` is added.
/// Encoded representations are not range-addressable; a request carrying
/// `Range` always receives the raw file.
pub const StaticFiles = struct {
    dir: std.Io.Dir,
    max_file_bytes: usize = 16 * 1024 * 1024,
    cache_control: ?[]const u8 = default_cache_control,
    index_file: ?[]const u8 = "index.html",
    allow_dotfiles: bool = false,
    follow_symlinks: bool = false,
    precompressed: bool = true,
    mime_types: []const MimeType = &default_mime_types,

    pub fn handler(self: *StaticFiles) ctx_mod.Handler {
        return ctx_mod.withContext(StaticFiles, self, serve);
    }

    fn serve(self: *StaticFiles, ctx: *ctx_mod.Ctx) anyerror!void {
        if (ctx.method() != .GET and ctx.method() != .HEAD) {
            ctx.setStatus(405);
            try ctx.setHeader("Allow", "GET, HEAD");
            return ctx.text("Method Not Allowed");
        }

        const raw = ctx.param("*") orelse {
            return notFound(ctx);
        };
        const path = normalizePath(
            ctx.arena,
            raw,
            self.allow_dotfiles,
        ) catch |err| switch (err) {
            error.InvalidPath => {
                ctx.setStatus(400);
                return ctx.text("Bad Request");
            },
            error.HiddenPath => return notFound(ctx),
            else => return err,
        };

        var relative = path;
        var stat = self.dir.statFile(ctx.io, relative, .{
            .follow_symlinks = self.follow_symlinks,
        }) catch return notFound(ctx);

        if (stat.kind == .directory) {
            const index = self.index_file orelse return notFound(ctx);
            relative = if (relative.len == 0)
                try ctx.arena.dupe(u8, index)
            else
                try std.fmt.allocPrint(
                    ctx.arena,
                    "{s}/{s}",
                    .{ relative, index },
                );
            stat = self.dir.statFile(ctx.io, relative, .{
                .follow_symlinks = self.follow_symlinks,
            }) catch return notFound(ctx);
        }

        if (stat.kind != .file) return notFound(ctx);
        if (stat.size > self.max_file_bytes or
            stat.size > ctx.limits.max_response_bytes)
        {
            ctx.setStatus(413);
            return ctx.text("Content Too Large");
        }

        const mime = self.contentType(relative);

        var served_relative = relative;
        var served_stat = stat;
        var content_encoding: ?[]const u8 = null;
        if (self.precompressed) {
            try addVary(ctx, "Accept-Encoding");
            if (ctx.header("range") == null) {
                if (chooseVariant(ctx.header("accept-encoding"))) |variant| {
                    const sidecar = try std.fmt.allocPrint(
                        ctx.arena,
                        "{s}{s}",
                        .{ relative, variant.extension },
                    );
                    if (self.dir.statFile(ctx.io, sidecar, .{
                        .follow_symlinks = self.follow_symlinks,
                    }) catch null) |sidecar_stat| {
                        if (sidecar_stat.kind == .file and
                            sidecar_stat.size <= self.max_file_bytes and
                            sidecar_stat.size <= ctx.limits.max_response_bytes)
                        {
                            served_relative = sidecar;
                            served_stat = sidecar_stat;
                            content_encoding = variant.encoding;
                        }
                    }
                }
            }
        }

        const size: usize = @intCast(served_stat.size);
        const etag = try std.fmt.allocPrint(
            ctx.arena,
            "\"{d}-{d}\"",
            .{ served_stat.size, served_stat.mtime.nanoseconds },
        );
        const last_modified: i64 = @intCast(@divFloor(
            served_stat.mtime.nanoseconds,
            std.time.ns_per_s,
        ));
        const last_modified_value = precondition.formatDate(last_modified);

        const preconditions = precondition.evaluate(.{
            .if_match = ctx.header("if-match"),
            .if_none_match = ctx.header("if-none-match"),
            .if_modified_since = ctx.header("if-modified-since"),
            .if_unmodified_since = ctx.header("if-unmodified-since"),
            .if_range = ctx.header("if-range"),
            .range = if (content_encoding == null)
                ctx.header("range")
            else
                null,
        }, etag, last_modified);
        switch (preconditions.outcome) {
            .precondition_failed => {
                try ctx.setHeader("ETag", etag);
                try ctx.setHeader("Last-Modified", &last_modified_value);
                if (self.cache_control) |cache| try ctx.setHeader(
                    "Cache-Control",
                    cache,
                );
                ctx.setStatus(412);
                return ctx.text("Precondition Failed");
            },
            .not_modified => {
                try ctx.setHeader("ETag", etag);
                try ctx.setHeader("Last-Modified", &last_modified_value);
                if (self.cache_control) |cache| try ctx.setHeader(
                    "Cache-Control",
                    cache,
                );
                ctx.setStatus(304);
                return;
            },
            .proceed => {},
        }

        var ranges: ?RangeSet = null;
        const range_allowed = preconditions.range_allowed;
        if (range_allowed) {
            if (ctx.header("range")) |range_header| {
                switch (parseRange(range_header, size)) {
                    .ignore => {},
                    .unsatisfiable => {
                        ctx.setStatus(416);
                        try ctx.setHeader(
                            "Content-Range",
                            try std.fmt.allocPrint(
                                ctx.arena,
                                "bytes */{d}",
                                .{size},
                            ),
                        );
                        return ctx.text("Range Not Satisfiable");
                    },
                    .ranges => |set| ranges = set,
                }
            }
        }

        var multipart: ?Multipart = null;
        if (ranges) |set| {
            if (set.count > 1) {
                multipart = self.prepareMultipart(
                    ctx,
                    set,
                    mime,
                    size,
                ) catch |err| switch (err) {
                    error.PayloadTooLarge => {
                        ctx.setStatus(413);
                        return ctx.text("Content Too Large");
                    },
                    else => return err,
                };
            }
        }

        const file = self.dir.openFile(ctx.io, served_relative, .{
            .mode = .read_only,
            .allow_directory = false,
        }) catch return notFound(ctx);
        errdefer file.close(ctx.io);

        try ctx.setHeader("ETag", etag);
        try ctx.setHeader("Last-Modified", &last_modified_value);
        if (content_encoding == null) {
            try ctx.setHeader("Accept-Ranges", "bytes");
        }
        if (content_encoding) |encoding| {
            try ctx.setHeader("Content-Encoding", encoding);
        }
        if (self.cache_control) |cache| {
            try ctx.setHeader("Cache-Control", cache);
        }

        if (multipart) |multi| {
            const state = try ctx.arena.create(MultiRange);
            state.* = .{
                .file = file,
                .io = ctx.io,
                .parts = multi.parts,
                .count = multi.count,
                .headers = multi.headers,
                .final = multi.final,
            };
            ctx.setStatus(206);
            try ctx.setHeader("Content-Type", multi.content_type);
            try ctx.stream(.{
                .context = state,
                .write_fn = writeMulti,
                .length = multi.length,
                .cancel_fn = cancelMulti,
            });
            return;
        }

        const start: usize = if (ranges) |set| set.parts[0].start else 0;
        const length: usize = if (ranges) |set| set.parts[0].length else size;
        const partial = ranges != null;

        const state = try ctx.arena.create(FileStream);
        state.* = .{
            .file = file,
            .io = ctx.io,
            .offset = start,
            .length = length,
        };

        try ctx.setHeader("Content-Type", mime);
        if (partial) {
            ctx.setStatus(206);
            try ctx.setHeader(
                "Content-Range",
                try std.fmt.allocPrint(
                    ctx.arena,
                    "bytes {d}-{d}/{d}",
                    .{ start, start + length - 1, size },
                ),
            );
        }

        try ctx.stream(.{
            .context = state,
            .write_fn = writeFile,
            .length = length,
            .cancel_fn = cancelFile,
        });
    }

    fn prepareMultipart(
        self: *StaticFiles,
        ctx: *ctx_mod.Ctx,
        set: RangeSet,
        mime: []const u8,
        size: usize,
    ) !Multipart {
        _ = self;
        var boundary_bytes: [16]u8 = undefined;
        try std.Io.randomSecure(ctx.io, &boundary_bytes);
        const hex = std.fmt.bytesToHex(boundary_bytes, .lower);
        const boundary = try ctx.arena.dupe(u8, &hex);

        var multipart = Multipart{
            .count = set.count,
            .content_type = try std.fmt.allocPrint(
                ctx.arena,
                "multipart/byteranges; boundary={s}",
                .{boundary},
            ),
        };
        var total: usize = 0;
        for (set.parts[0..set.count], 0..) |part, index| {
            multipart.parts[index] = part;
            const header = try std.fmt.allocPrint(
                ctx.arena,
                "--{s}\r\nContent-Type: {s}\r\nContent-Range: bytes {d}-{d}/{d}\r\n\r\n",
                .{
                    boundary,
                    mime,
                    part.start,
                    part.start + part.length - 1,
                    size,
                },
            );
            multipart.headers[index] = header;
            total = std.math.add(usize, total, header.len) catch
                return error.PayloadTooLarge;
            total = std.math.add(usize, total, part.length) catch
                return error.PayloadTooLarge;
            total = std.math.add(usize, total, 2) catch
                return error.PayloadTooLarge;
        }
        multipart.final = try std.fmt.allocPrint(
            ctx.arena,
            "--{s}--\r\n",
            .{boundary},
        );
        total = std.math.add(usize, total, multipart.final.len) catch
            return error.PayloadTooLarge;
        if (total > ctx.limits.max_response_bytes) {
            return error.PayloadTooLarge;
        }
        multipart.length = total;
        return multipart;
    }

    fn contentType(self: *const StaticFiles, path: []const u8) []const u8 {
        const basename = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0)..];
        const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse
            return "application/octet-stream";
        const extension = basename[dot..];
        for (self.mime_types) |mime| {
            if (std.ascii.eqlIgnoreCase(mime.extension, extension)) {
                return mime.content_type;
            }
        }
        return "application/octet-stream";
    }
};

const FileStream = struct {
    file: std.Io.File,
    io: std.Io,
    offset: usize,
    length: usize,
};

const Multipart = struct {
    parts: [max_ranges]RangePart = undefined,
    count: usize,
    headers: [max_ranges][]const u8 = undefined,
    final: []const u8 = undefined,
    content_type: []const u8,
    length: usize = undefined,
};

const MultiRange = struct {
    file: std.Io.File,
    io: std.Io,
    parts: [max_ranges]RangePart,
    count: usize,
    headers: [max_ranges][]const u8,
    final: []const u8,
};

fn writeFile(raw: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
    const state: *FileStream = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    defer state.file.close(state.io);
    try writeRange(state.file, state.io, state.offset, state.length, writer);
}

fn cancelFile(raw: ?*anyopaque) void {
    const state: *FileStream = @ptrCast(@alignCast(raw orelse return));
    state.file.close(state.io);
}

fn writeMulti(raw: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
    const state: *MultiRange = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    defer state.file.close(state.io);

    for (state.parts[0..state.count], 0..) |part, index| {
        try writer.write(state.headers[index]);
        try writeRange(
            state.file,
            state.io,
            part.start,
            part.length,
            writer,
        );
        try writer.write("\r\n");
    }
    try writer.write(state.final);
}

fn cancelMulti(raw: ?*anyopaque) void {
    const state: *MultiRange = @ptrCast(@alignCast(raw orelse return));
    state.file.close(state.io);
}

fn writeRange(
    file: std.Io.File,
    io: std.Io,
    offset_start: usize,
    length: usize,
    writer: *stream_mod.Writer,
) anyerror!void {
    var buffer: [16 * 1024]u8 = undefined;
    var offset = offset_start;
    var remaining = length;
    while (remaining > 0) {
        const want = @min(remaining, buffer.len);
        const parts = [_][]u8{buffer[0..want]};
        const read = try file.readPositional(io, &parts, offset);
        if (read == 0) return error.UnexpectedEof;
        try writer.write(buffer[0..read]);
        offset += read;
        remaining -= read;
    }
}

fn notFound(ctx: *ctx_mod.Ctx) anyerror!void {
    ctx.setStatus(404);
    return ctx.text("Not Found");
}

/// Encodings are listed in descending preference so equal `q` values resolve
/// to `br` first, then `zstd`, then `gzip`.
const Variant = struct {
    extension: []const u8,
    encoding: []const u8,
};

const variants = [_]Variant{
    .{ .extension = ".br", .encoding = "br" },
    .{ .extension = ".zst", .encoding = "zstd" },
    .{ .extension = ".gz", .encoding = "gzip" },
};

/// Select the best acceptable precompressed variant, honouring `q` weights and
/// the `*` wildcard. Returns null when the client accepts no known encoding.
fn chooseVariant(header: ?[]const u8) ?Variant {
    const value = header orelse return null;

    var star_quality: ?u16 = null;
    var qualities = [_]?u16{null} ** variants.len;

    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t");
        if (token.len == 0) continue;

        var parameters = std.mem.splitScalar(u8, token, ';');
        const coding = std.mem.trim(u8, parameters.next() orelse continue, " \t");
        if (coding.len == 0) continue;

        var quality: u16 = 1000;
        while (parameters.next()) |raw_parameter| {
            const parameter = std.mem.trim(u8, raw_parameter, " \t");
            if (std.ascii.startsWithIgnoreCase(parameter, "q=")) {
                quality = parseQuality(parameter["q=".len..]) orelse 0;
            }
        }

        if (std.mem.eql(u8, coding, "*")) {
            star_quality = quality;
            continue;
        }
        for (variants, 0..) |variant, index| {
            if (std.ascii.eqlIgnoreCase(coding, variant.encoding)) {
                qualities[index] = quality;
            }
        }
    }

    var best: ?Variant = null;
    var best_quality: u16 = 0;
    for (variants, 0..) |variant, index| {
        const quality = qualities[index] orelse star_quality orelse continue;
        if (quality <= best_quality) continue;
        best = variant;
        best_quality = quality;
    }
    return best;
}

/// Parse an HTTP `q` value into thousandths, e.g. `0.5` becomes `500`.
fn parseQuality(text: []const u8) ?u16 {
    const value = std.mem.trim(u8, text, " \t");
    if (value.len == 0) return null;

    var whole: u16 = 0;
    var fraction: u16 = 0;
    var fraction_digits: u16 = 0;
    var seen_dot = false;
    for (value) |char| {
        if (char == '.') {
            if (seen_dot) return null;
            seen_dot = true;
            continue;
        }
        if (char < '0' or char > '9') return null;
        const digit: u16 = char - '0';
        if (seen_dot) {
            if (fraction_digits == 3) return null;
            fraction = fraction * 10 + digit;
            fraction_digits += 1;
        } else {
            if (whole >= 2) return null;
            whole = whole * 10 + digit;
        }
    }
    if (whole > 1) return null;
    while (fraction_digits < 3) : (fraction_digits += 1) fraction *= 10;
    if (whole == 1 and fraction != 0) return null;
    return whole * 1000 + fraction;
}

/// Append `value` to `Vary` unless it (or `*`) is already present.
fn addVary(ctx: *ctx_mod.Ctx, value: []const u8) !void {
    const existing = ctx.header("vary") orelse {
        return ctx.setHeader("Vary", value);
    };
    var tokens = std.mem.splitScalar(u8, existing, ',');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t");
        if (std.mem.eql(u8, token, "*") or
            std.ascii.eqlIgnoreCase(token, value))
        {
            return;
        }
    }
    return ctx.setHeader(
        "Vary",
        try std.fmt.allocPrint(ctx.arena, "{s}, {s}", .{ existing, value }),
    );
}

fn normalizePath(
    allocator: std.mem.Allocator,
    raw: []const u8,
    allow_dotfiles: bool,
) ![]const u8 {
    if (raw.len == 0) return "";

    var segments = std.ArrayListUnmanaged([]const u8).empty;
    defer segments.deinit(allocator);

    var iterator = std.mem.splitScalar(u8, raw, '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return error.InvalidPath;
        if (!allow_dotfiles and segment[0] == '.') return error.HiddenPath;
        for (segment) |char| {
            if (char == '\\' or char == 0 or char < 0x20 or char == 0x7f) {
                return error.InvalidPath;
            }
        }
        if (segments.items.len >= max_segments) return error.InvalidPath;
        try segments.append(allocator, segment);
    }

    if (segments.items.len == 0) return "";
    return std.mem.join(allocator, "/", segments.items);
}

const max_ranges = 16;

const RangePart = struct {
    start: usize,
    length: usize,
};

const RangeSet = struct {
    parts: [max_ranges]RangePart = undefined,
    count: usize = 0,
};

const Range = union(enum) {
    ignore,
    unsatisfiable,
    ranges: RangeSet,
};

const ParsedRange = union(enum) {
    ignore,
    unsatisfiable,
    range: RangePart,
};

fn parseRange(header: []const u8, size: usize) Range {
    const value = std.mem.trim(u8, header, " \t");
    if (!std.ascii.startsWithIgnoreCase(value, "bytes=")) return .ignore;
    const spec = std.mem.trim(u8, value["bytes=".len..], " \t");
    if (spec.len == 0) return .ignore;

    var set = RangeSet{};
    var iterator = std.mem.splitScalar(u8, spec, ',');
    while (iterator.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) return .ignore;
        switch (parseOneRange(part, size)) {
            .ignore => return .ignore,
            .unsatisfiable => continue,
            .range => |range| {
                if (set.count >= max_ranges) return .ignore;
                set.parts[set.count] = range;
                set.count += 1;
            },
        }
    }

    if (set.count == 0) return .unsatisfiable;
    return .{ .ranges = set };
}

fn parseOneRange(spec: []const u8, size: usize) ParsedRange {
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .ignore;
    const first = std.mem.trim(u8, spec[0..dash], " \t");
    const last = std.mem.trim(u8, spec[dash + 1 ..], " \t");

    if (size == 0) return .unsatisfiable;

    if (first.len == 0) {
        const suffix = parseUsize(last) orelse return .ignore;
        if (suffix == 0) return .unsatisfiable;
        const length = @min(suffix, size);
        return .{ .range = .{
            .start = size - length,
            .length = length,
        } };
    }

    const start = parseUsize(first) orelse return .ignore;
    if (start >= size) return .unsatisfiable;
    const end = if (last.len == 0)
        size - 1
    else
        parseUsize(last) orelse return .ignore;
    if (end < start) return .unsatisfiable;
    const clamped_end = @min(end, size - 1);
    return .{ .range = .{
        .start = start,
        .length = clamped_end - start + 1,
    } };
}

fn parseUsize(text: []const u8) ?usize {
    if (text.len == 0) return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

test "static path normalization rejects traversal and dotfiles" {
    const allocator = std.testing.allocator;
    const arena = try allocator.alloc(u8, 4096);
    defer allocator.free(arena);
    var fixed = std.heap.FixedBufferAllocator.init(arena);
    const alloc = fixed.allocator();

    try std.testing.expectEqualStrings(
        "css/site.css",
        try normalizePath(alloc, "css/site.css", false),
    );
    try std.testing.expectEqualStrings(
        "css/site.css",
        try normalizePath(alloc, "./css//site.css", false),
    );
    try std.testing.expectError(
        error.InvalidPath,
        normalizePath(alloc, "../secret", false),
    );
    try std.testing.expectError(
        error.InvalidPath,
        normalizePath(alloc, "css/../../secret", false),
    );
    try std.testing.expectError(
        error.HiddenPath,
        normalizePath(alloc, ".git/config", false),
    );
    try std.testing.expectError(
        error.InvalidPath,
        normalizePath(alloc, "css\\site.css", false),
    );
}

test "static range parsing handles single, suffix, and multiple ranges" {
    const single = parseRange("bytes=0-9", 10).ranges;
    try std.testing.expectEqual(@as(usize, 1), single.count);
    try std.testing.expectEqual(@as(usize, 0), single.parts[0].start);
    try std.testing.expectEqual(@as(usize, 10), single.parts[0].length);

    const open = parseRange("bytes=5-", 10).ranges;
    try std.testing.expectEqual(@as(usize, 5), open.parts[0].start);
    try std.testing.expectEqual(@as(usize, 5), open.parts[0].length);

    const suffix = parseRange("bytes=-5", 10).ranges;
    try std.testing.expectEqual(@as(usize, 5), suffix.parts[0].start);
    try std.testing.expectEqual(@as(usize, 5), suffix.parts[0].length);

    const multiple = parseRange("bytes=0-1,3-4", 10).ranges;
    try std.testing.expectEqual(@as(usize, 2), multiple.count);
    try std.testing.expectEqual(@as(usize, 0), multiple.parts[0].start);
    try std.testing.expectEqual(@as(usize, 2), multiple.parts[0].length);
    try std.testing.expectEqual(@as(usize, 3), multiple.parts[1].start);
    try std.testing.expectEqual(@as(usize, 2), multiple.parts[1].length);

    const mixed = parseRange("bytes=0-1,20-", 10).ranges;
    try std.testing.expectEqual(@as(usize, 1), mixed.count);
    try std.testing.expect(parseRange("bytes=20-", 10) == .unsatisfiable);
    try std.testing.expect(parseRange("bytes=", 10) == .ignore);
}

test "static variant selection honours q values and wildcards" {
    try std.testing.expect(chooseVariant(null) == null);
    try std.testing.expect(chooseVariant("identity") == null);
    try std.testing.expect(chooseVariant("gzip;q=0") == null);

    const gzip = chooseVariant("gzip").?;
    try std.testing.expectEqualStrings("gzip", gzip.encoding);
    try std.testing.expectEqualStrings(".gz", gzip.extension);

    // Equal weights prefer brotli, then zstd, then gzip.
    try std.testing.expectEqualStrings(
        "br",
        chooseVariant("gzip, br, zstd").?.encoding,
    );
    try std.testing.expectEqualStrings(
        "zstd",
        chooseVariant("gzip;q=0.8, zstd;q=0.9").?.encoding,
    );
    try std.testing.expectEqualStrings(
        "gzip",
        chooseVariant("gzip;q=1.0, br;q=0.5").?.encoding,
    );

    // Explicit weights override the wildcard, and `q=0` excludes a coding.
    try std.testing.expectEqualStrings(
        "gzip",
        chooseVariant("*;q=0.5, gzip;q=0.9").?.encoding,
    );
    try std.testing.expect(chooseVariant("*;q=0") == null);
    try std.testing.expectEqualStrings(
        "br",
        chooseVariant("*;q=0, br;q=0.5").?.encoding,
    );
    try std.testing.expectEqualStrings(
        "br",
        chooseVariant("*").?.encoding,
    );

    // Unknown codings are ignored; uppercase names are accepted.
    try std.testing.expectEqualStrings(
        "gzip",
        chooseVariant("deflate, GZIP").?.encoding,
    );
}

test "static quality parsing clamps malformed values" {
    try std.testing.expectEqual(@as(?u16, 1000), parseQuality("1"));
    try std.testing.expectEqual(@as(?u16, 1000), parseQuality("1.000"));
    try std.testing.expectEqual(@as(?u16, 500), parseQuality("0.5"));
    try std.testing.expectEqual(@as(?u16, 50), parseQuality("0.05"));
    try std.testing.expectEqual(@as(?u16, 0), parseQuality("0"));
    try std.testing.expect(parseQuality("1.5") == null);
    try std.testing.expect(parseQuality("2") == null);
    try std.testing.expect(parseQuality("") == null);
    try std.testing.expect(parseQuality("abc") == null);
}
