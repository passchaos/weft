const std = @import("std");

/// Maximum path segments accepted by static-file normalization.
pub const max_segments = 128;

pub fn fileName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        return path;
    return path[slash + 1 ..];
}

pub fn targetEndsWithSlash(target: []const u8) bool {
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return path_end > 0 and target[path_end - 1] == '/';
}

pub fn directoryLocation(
    allocator: std.mem.Allocator,
    target: []const u8,
) ![]const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const path = if (query_start) |index| target[0..index] else target;
    const query = if (query_start) |index| target[index..] else "";
    if (path.len == 0) return std.fmt.allocPrint(allocator, "/{s}", .{query});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, query });
}

pub fn normalizePath(
    allocator: std.mem.Allocator,
    raw: []const u8,
    allow_dotfiles: bool,
) ![]const u8 {
    if (raw.len == 0) return "";
    // A plain relative path is already normalized and stays borrowed from the
    // request arena.
    if (isPlainRelativePath(raw, allow_dotfiles)) return raw;

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

/// True when `raw` has no empty, dot, dot-dot, hidden, or invalid segments,
/// so normalization would return the input unchanged.
fn isPlainRelativePath(raw: []const u8, allow_dotfiles: bool) bool {
    var segment_start: usize = 0;
    var segment_count: usize = 0;
    var index: usize = 0;
    while (index <= raw.len) : (index += 1) {
        if (index < raw.len and raw[index] != '/') {
            const char = raw[index];
            if (char == '\\' or char == 0 or char < 0x20 or char == 0x7f) {
                return false;
            }
            continue;
        }
        const segment = raw[segment_start..index];
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or
            std.mem.eql(u8, segment, ".."))
        {
            return false;
        }
        if (!allow_dotfiles and segment[0] == '.') return false;
        segment_count += 1;
        if (segment_count > max_segments) return false;
        segment_start = index + 1;
    }
    return true;
}
