const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const router_mod = @import("../router.zig");

/// Maximum number of path segments accepted by the matcher. The bound keeps
/// recursive traversal and node teardown stack-safe for hostile targets.
pub const max_path_segments = 128;

pub const Node = struct {
    static_children: std.StringHashMapUnmanaged(*Node) = .empty,
    /// Fast path for the common case of exactly one static child. When set,
    /// `static_children` is empty and `single_key` owns the child's name.
    single_key: ?[]const u8 = null,
    single_child: ?*Node = null,
    param: ?*Node = null,
    routes: std.ArrayListUnmanaged(*router_mod.Route) = .empty,
    wildcard_routes: std.ArrayListUnmanaged(*router_mod.Route) = .empty,
};

pub const Segment = struct {
    text: []const u8,
    start: usize,
};

pub const SegmentIterator = struct {
    source: []const u8,
    position: usize = 0,

    pub fn next(self: *SegmentIterator) ?Segment {
        if (self.position >= self.source.len) return null;
        const start = self.position;
        const end = std.mem.indexOfScalarPos(
            u8,
            self.source,
            self.position,
            '/',
        ) orelse self.source.len;
        self.position = if (end < self.source.len) end + 1 else end;
        return .{ .text = self.source[start..end], .start = start };
    }
};

pub const Captures = struct {
    values: [handler_mod.max_params][]const u8 = undefined,
    count: usize = 0,
};

pub const PatternInfo = struct {
    captures: usize,
    segments: usize,
};

pub fn validatePattern(pattern: []const u8) !PatternInfo {
    if (pattern.len == 0 or pattern[0] != '/') return error.InvalidPattern;

    // Allow trailing slashes (`/users/` equals `/users`) but reject interior
    // or repeated empty segments, which would otherwise create ambiguous
    // matches.
    const trimmed = std.mem.trimEnd(u8, pattern[1..], "/");
    if (trimmed.len == 0) return .{ .captures = 0, .segments = 0 };

    var captures: usize = 0;
    var segments_count: usize = 0;
    var segments = SegmentIterator{ .source = trimmed };
    while (segments.next()) |segment| {
        segments_count += 1;
        if (segments_count > max_path_segments) return error.PatternTooDeep;
        if (segment.text.len == 0) return error.InvalidPattern;
        for (segment.text) |char| {
            if (char == '?' or char == '#' or char < 0x20 or char == 0x7f) {
                return error.InvalidPattern;
            }
        }
        if (segment.text[0] == ':') {
            if (segment.text.len == 1) return error.InvalidPattern;
            captures += 1;
        } else if (segment.text[0] == '*') {
            if (!std.mem.eql(u8, segment.text, "*")) return error.InvalidPattern;
            if (segments.next() != null) return error.InvalidPattern;
            captures += 1;
            break;
        }
        if (captures > handler_mod.max_params) return error.TooManyParams;
    }
    return .{ .captures = captures, .segments = segments_count };
}

pub fn computeSpecificity(pattern: []const u8) u32 {
    var score: u32 = 0;
    const trimmed = std.mem.trim(u8, pattern, "/");
    var segments = SegmentIterator{ .source = trimmed };
    while (segments.next()) |segment| {
        if (segment.text.len > 0 and segment.text[0] == ':') {
            score += 2;
        } else if (std.mem.eql(u8, segment.text, "*")) {
            score += 1;
        } else {
            score += 4;
        }
    }
    return score;
}

pub fn routeMatches(
    route_method: ?netz.http1.Method,
    request_method: netz.http1.Method,
) bool {
    const method = route_method orelse return true;
    return methodEqual(method, request_method);
}

pub fn methodEqual(a: netz.http1.Method, b: netz.http1.Method) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .extension => |a_extension| switch (b) {
            .extension => |b_extension| std.mem.eql(u8, a_extension, b_extension),
            else => false,
        },
        else => true,
    };
}
