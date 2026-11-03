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

        var start: usize = 0;
        var length: usize = size;
        var partial = false;
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
                .range => |range| {
                    start = range.start;
                    length = range.length;
                    partial = true;
                },
            }
        }

        const file = self.dir.openFile(ctx.io, relative, .{
            .mode = .read_only,
            .allow_directory = false,
        }) catch return notFound(ctx);
        errdefer file.close(ctx.io);

        const state = try ctx.arena.create(FileStream);
        state.* = .{
            .file = file,
            .io = ctx.io,
            .offset = start,
            .length = length,
        };

        try ctx.setHeader("Content-Type", self.contentType(relative));
        try ctx.setHeader("ETag", etag);
        try ctx.setHeader("Accept-Ranges", "bytes");
        if (self.cache_control) |cache| {
            try ctx.setHeader("Cache-Control", cache);
        }
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

fn writeFile(raw: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
    const state: *FileStream = @ptrCast(@alignCast(raw orelse
        return error.InvalidWriterState));
    defer state.file.close(state.io);

    var buffer: [16 * 1024]u8 = undefined;
    var offset = state.offset;
    var remaining = state.length;
    while (remaining > 0) {
        const want = @min(remaining, buffer.len);
        const parts = [_][]u8{buffer[0..want]};
        const read = try state.file.readPositional(
            state.io,
            &parts,
            offset,
        );
        if (read == 0) return error.UnexpectedEof;
        try writer.write(buffer[0..read]);
        offset += read;
        remaining -= read;
    }
}

fn cancelFile(raw: ?*anyopaque) void {
    const state: *FileStream = @ptrCast(@alignCast(raw orelse return));
    state.file.close(state.io);
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

const Range = union(enum) {
    ignore,
    unsatisfiable,
    range: struct {
        start: usize,
        length: usize,
    },
};

fn parseRange(header: []const u8, size: usize) Range {
    const value = std.mem.trim(u8, header, " \t");
    if (!std.ascii.startsWithIgnoreCase(value, "bytes=")) return .ignore;
    const spec = std.mem.trim(u8, value["bytes=".len..], " \t");
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .ignore;

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

test "static range parsing handles single and suffix ranges" {
    try std.testing.expectEqual(
        @as(usize, 0),
        parseRange("bytes=0-9", 10).range.start,
    );
    try std.testing.expectEqual(
        @as(usize, 10),
        parseRange("bytes=0-9", 10).range.length,
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        parseRange("bytes=5-", 10).range.start,
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        parseRange("bytes=5-", 10).range.length,
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        parseRange("bytes=-5", 10).range.start,
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        parseRange("bytes=-5", 10).range.length,
    );
    try std.testing.expect(parseRange("bytes=20-", 10) == .unsatisfiable);
    try std.testing.expect(parseRange("bytes=0-1,3-4", 10) == .ignore);
}

test "static etag matching accepts weak and wildcard forms" {
    try std.testing.expect(etagMatches("\"abc\"", "\"abc\""));
    try std.testing.expect(etagMatches("W/\"abc\"", "\"abc\""));
    try std.testing.expect(etagMatches("*", "\"abc\""));
    try std.testing.expect(!etagMatches("\"other\"", "\"abc\""));
}
