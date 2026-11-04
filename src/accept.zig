//! `Accept` header content negotiation.
//!
//! Parsing is allocation-free: ranges are scanned on demand, so `accepts` and
//! `preferred` can run on every request without touching the arena.

const std = @import("std");

/// Return true when `accept` (the raw `Accept` field value) allows
/// `media_type` (`type/subtype`). A missing or empty header accepts anything.
/// The most specific matching range wins, so `text/*;q=0, */*;q=1` still
/// rejects `text/html`.
pub fn accepts(accept: ?[]const u8, media_type: []const u8) bool {
    const header = accept orelse return true;
    if (std.mem.trim(u8, header, " \t").len == 0) return true;

    const candidate = splitMediaType(media_type) orelse return false;
    var best_specificity: u8 = 0;
    var best_quality: ?f64 = null;

    var ranges = std.mem.splitScalar(u8, header, ',');
    while (ranges.next()) |raw| {
        const range = parseRange(raw) orelse continue;
        const specificity = range.specificity(candidate) orelse continue;
        if (specificity > best_specificity) {
            best_specificity = specificity;
            best_quality = range.quality;
        } else if (specificity == best_specificity and best_quality == null) {
            best_quality = range.quality;
        }
    }
    const quality = best_quality orelse return false;
    return quality > 0;
}

/// Choose the candidate with the highest accepted quality. Ties keep the
/// earliest candidate. Returns null when none is acceptable.
pub fn preferred(
    accept: ?[]const u8,
    candidates: []const []const u8,
) ?[]const u8 {
    const header = accept orelse return if (candidates.len != 0)
        candidates[0]
    else
        null;

    var best: ?[]const u8 = null;
    var best_quality: f64 = 0;
    for (candidates) |candidate| {
        const quality = qualityFor(header, candidate) orelse continue;
        if (quality <= 0) continue;
        if (best == null or quality > best_quality) {
            best = candidate;
            best_quality = quality;
        }
    }
    return best;
}

/// Effective quality for one candidate, or null when no range matches.
pub fn qualityFor(accept: []const u8, media_type: []const u8) ?f64 {
    const candidate = splitMediaType(media_type) orelse return null;
    var best_specificity: u8 = 0;
    var best_quality: ?f64 = null;

    var ranges = std.mem.splitScalar(u8, accept, ',');
    while (ranges.next()) |raw| {
        const range = parseRange(raw) orelse continue;
        const specificity = range.specificity(candidate) orelse continue;
        if (specificity > best_specificity) {
            best_specificity = specificity;
            best_quality = range.quality;
        } else if (specificity == best_specificity and best_quality == null) {
            best_quality = range.quality;
        }
    }
    return best_quality;
}

const MediaType = struct {
    type: []const u8,
    subtype: []const u8,
};

fn splitMediaType(value: []const u8) ?MediaType {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return null;
    const media_type = std.mem.trim(u8, value[0..slash], " \t");
    const subtype = std.mem.trim(u8, value[slash + 1 ..], " \t");
    if (media_type.len == 0 or subtype.len == 0) return null;
    return .{ .type = media_type, .subtype = subtype };
}

const Range = struct {
    type: []const u8,
    subtype: []const u8,
    quality: f64 = 1.0,

    /// 3 for `type/subtype`, 2 for `type/*`, 1 for `*/*`, null for no match.
    fn specificity(self: Range, candidate: MediaType) ?u8 {
        if (std.ascii.eqlIgnoreCase(self.type, "*")) return 1;
        if (!std.ascii.eqlIgnoreCase(self.type, candidate.type)) return null;
        if (std.ascii.eqlIgnoreCase(self.subtype, "*")) return 2;
        if (std.ascii.eqlIgnoreCase(self.subtype, candidate.subtype)) return 3;
        return null;
    }
};

fn parseRange(raw: []const u8) ?Range {
    const item = std.mem.trim(u8, raw, " \t");
    if (item.len == 0) return null;

    var parts = std.mem.splitScalar(u8, item, ';');
    const media = std.mem.trim(u8, parts.next() orelse return null, " \t");
    const split = splitMediaType(media) orelse return null;

    var quality: f64 = 1.0;
    while (parts.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        const equals = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const name = std.mem.trim(u8, param[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "q")) continue;
        quality = parseQuality(
            std.mem.trim(u8, param[equals + 1 ..], " \t"),
        ) orelse 0.0;
        break;
    }

    return .{
        .type = split.type,
        .subtype = split.subtype,
        .quality = quality,
    };
}

fn parseQuality(value: []const u8) ?f64 {
    const parsed = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(parsed) or parsed < 0 or parsed > 1) return null;
    return parsed;
}

test "accept negotiation handles exact, wildcard, and q=0" {
    try std.testing.expect(accepts(null, "application/json"));
    try std.testing.expect(accepts("*/*", "application/json"));
    try std.testing.expect(accepts("application/*", "application/json"));
    try std.testing.expect(accepts("text/html, application/json", "application/json"));
    try std.testing.expect(!accepts("text/html", "application/json"));
    try std.testing.expect(!accepts("application/json;q=0", "application/json"));
    try std.testing.expect(!accepts("", "application/json") == false);
}

test "accept negotiation prefers the most specific range" {
    // `text/*` rejects, but `*/*` allows; the more specific range wins.
    try std.testing.expect(!accepts("text/*;q=0, */*;q=1", "text/html"));
    // Explicit rejection beats a broader allowance.
    try std.testing.expect(!accepts("*/*, application/json;q=0", "application/json"));
    try std.testing.expect(accepts("*/*, application/json;q=0", "text/html"));
}

test "accept preferred picks the highest quality" {
    const candidates = [_][]const u8{
        "application/json",
        "text/html",
    };
    try std.testing.expectEqualStrings(
        "text/html",
        preferred("application/json;q=0.4, text/html;q=0.9", &candidates).?,
    );
    try std.testing.expectEqualStrings(
        "application/json",
        preferred("application/json, text/html;q=0.9", &candidates).?,
    );
    try std.testing.expect(preferred("image/png", &candidates) == null);
    try std.testing.expectEqualStrings(
        "application/json",
        preferred(null, &candidates).?,
    );
}

test "accept ignores media-type parameters and malformed quality" {
    try std.testing.expect(accepts(
        "application/json; charset=utf-8",
        "application/json",
    ));
    try std.testing.expect(!accepts("application/json;q=abc", "application/json"));
    try std.testing.expect(!accepts("application/json;q=2", "application/json"));
}
