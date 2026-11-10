const std = @import("std");
const quality_mod = @import("../../quality.zig");

const flate = std.compress.flate;

pub const Coding = enum {
    gzip,
    deflate,
    br,
    zstd,

    pub fn headerValue(self: Coding) []const u8 {
        return switch (self) {
            .gzip => "gzip",
            .deflate => "deflate",
            .br => "br",
            .zstd => "zstd",
        };
    }

    pub fn container(self: Coding) flate.Container {
        return switch (self) {
            .gzip => .gzip,
            .deflate => .zlib,
            .br, .zstd => unreachable,
        };
    }
};

pub const Negotiation = union(enum) {
    identity,
    not_acceptable,
    coding: Coding,
};

pub fn noTransform(cache_control: ?[]const u8) bool {
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

pub fn quality(params: []const u8) ?u16 {
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

pub fn compressible(content_type: ?[]const u8) bool {
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

pub fn containsToken(value: []const u8, token: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, part, " \t"),
            token,
        )) return true;
    }
    return false;
}
