const std = @import("std");
const ctx_mod = @import("ctx.zig");
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
pub const StaticFiles = struct {
    dir: std.Io.Dir,
    max_file_bytes: usize = 16 * 1024 * 1024,
    cache_control: ?[]const u8 = default_cache_control,
    index_file: ?[]const u8 = "index.html",
    allow_dotfiles: bool = false,
    follow_symlinks: bool = false,
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

        const size: usize = @intCast(stat.size);
        const etag = try std.fmt.allocPrint(
            ctx.arena,
            "\"{d}-{d}\"",
            .{ stat.size, stat.mtime.nanoseconds },
        );

        if (ctx.header("if-none-match")) |if_none_match| {
            if (etagMatches(if_none_match, etag)) {
                try ctx.setHeader("ETag", etag);
                if (self.cache_control) |cache| try ctx.setHeader(
                    "Cache-Control",
                    cache,
                );
                ctx.setStatus(304);
                return;
            }
        }

        const mime = self.contentType(relative);

        var ranges: ?RangeSet = null;
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

        const file = self.dir.openFile(ctx.io, relative, .{
            .mode = .read_only,
            .allow_directory = false,
        }) catch return notFound(ctx);
        errdefer file.close(ctx.io);

        try ctx.setHeader("ETag", etag);
        try ctx.setHeader("Accept-Ranges", "bytes");
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

fn etagMatches(header: []const u8, etag: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, header, ',');
    while (iterator.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, token, "*")) return true;
        const candidate = if (std.ascii.startsWithIgnoreCase(token, "W/"))
            token[2..]
        else
            token;
        if (std.mem.eql(u8, candidate, etag)) return true;
    }
    return false;
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

test "static etag matching accepts weak and wildcard forms" {
    try std.testing.expect(etagMatches("\"abc\"", "\"abc\""));
    try std.testing.expect(etagMatches("W/\"abc\"", "\"abc\""));
    try std.testing.expect(etagMatches("*", "\"abc\""));
    try std.testing.expect(!etagMatches("\"other\"", "\"abc\""));
}
