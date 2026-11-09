//! `Accept` header content negotiation.
//!
//! Parsing is allocation-free: ranges are scanned on demand, so `accepts` and
//! `preferred` can run on every request without touching the arena.
//! `preferred` parses the header once and evaluates every candidate against
//! the parsed ranges; only headers with more than `max_parsed_ranges` ranges
//! fall back to the per-candidate scan.

const std = @import("std");
const quality_mod = @import("quality.zig");

/// Maximum ranges parsed into the fast-path array. Real browsers send a
/// handful; a larger header falls back to the per-candidate scan.
const max_parsed_ranges = 16;

/// Quality in thousandths, matching HTTP's three-digit `q` grammar.
const Weight = u16;

/// Return true when `accept` (the raw `Accept` field value) allows
/// `media_type` (`type/subtype`). A missing or empty header accepts anything.
/// The most specific matching range wins, so `text/*;q=0, */*;q=1` still
/// rejects `text/html`.
pub fn accepts(accept: ?[]const u8, media_type: []const u8) bool {
    const header = accept orelse return true;
    if (std.mem.trim(u8, header, " \t").len == 0) return true;

    const candidate = splitMediaType(media_type) orelse return false;
    var best_specificity: u8 = 0;
    var best_weight: ?Weight = null;

    var ranges = std.mem.splitScalar(u8, header, ',');
    while (ranges.next()) |raw| {
        const range = parseRange(raw) orelse continue;
        const specificity = range.specificity(candidate) orelse continue;
        if (specificity > best_specificity) {
            best_specificity = specificity;
            best_weight = range.weight;
        } else if (specificity == best_specificity and best_weight == null) {
            best_weight = range.weight;
        }
    }
    const weight = best_weight orelse return false;
    return weight > 0;
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
    // Match `accepts`: an empty Accept field value accepts anything.
    if (std.mem.trim(u8, header, " \t").len == 0) {
        return if (candidates.len != 0) candidates[0] else null;
    }

    var parsed = Parsed{};
    var ranges = std.mem.splitScalar(u8, header, ',');
    while (ranges.next()) |raw| {
        const range = parseRange(raw) orelse continue;
        if (parsed.len == max_parsed_ranges) {
            return preferredByScan(header, candidates);
        }
        parsed.items[parsed.len] = range;
        parsed.len += 1;
    }

    var best: ?[]const u8 = null;
    var best_weight: Weight = 0;
    for (candidates) |candidate| {
        const weight = qualityFromRanges(
            parsed.items[0..parsed.len],
            candidate,
        ) orelse continue;
        if (weight == 0) continue;
        if (best == null or weight > best_weight) {
            best = candidate;
            best_weight = weight;
        }
    }
    return best;
}

/// Effective quality for one candidate, or null when no range matches.
/// Values are returned as a fraction so callers can compare them directly.
pub fn qualityFor(accept: []const u8, media_type: []const u8) ?f64 {
    const weight = qualityWeight(accept, media_type) orelse return null;
    return @as(f64, @floatFromInt(weight)) / 1000.0;
}

const Parsed = struct {
    items: [max_parsed_ranges]Range = undefined,
    len: usize = 0,
};

fn preferredByScan(
    header: []const u8,
    candidates: []const []const u8,
) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_weight: Weight = 0;
    for (candidates) |candidate| {
        const weight = qualityWeight(header, candidate) orelse continue;
        if (weight == 0) continue;
        if (best == null or weight > best_weight) {
            best = candidate;
            best_weight = weight;
        }
    }
    return best;
}

fn qualityWeight(accept: []const u8, media_type: []const u8) ?Weight {
    const candidate = splitMediaType(media_type) orelse return null;
    var best_specificity: u8 = 0;
    var best_weight: ?Weight = null;

    var ranges = std.mem.splitScalar(u8, accept, ',');
    while (ranges.next()) |raw| {
        const range = parseRange(raw) orelse continue;
        const specificity = range.specificity(candidate) orelse continue;
        if (specificity > best_specificity) {
            best_specificity = specificity;
            best_weight = range.weight;
        } else if (specificity == best_specificity and best_weight == null) {
            best_weight = range.weight;
        }
    }
    return best_weight;
}

fn qualityFromRanges(ranges: []const Range, media_type: []const u8) ?Weight {
    const candidate = splitMediaType(media_type) orelse return null;
    var best_specificity: u8 = 0;
    var best_weight: ?Weight = null;
    for (ranges) |range| {
        const specificity = range.specificity(candidate) orelse continue;
        if (specificity > best_specificity) {
            best_specificity = specificity;
            best_weight = range.weight;
        } else if (specificity == best_specificity and best_weight == null) {
            best_weight = range.weight;
        }
    }
    return best_weight;
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
    weight: Weight = 1000,

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

    var weight: Weight = 1000;
    while (parts.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        const equals = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const name = std.mem.trim(u8, param[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "q")) continue;
        weight = quality_mod.parse(
            std.mem.trim(u8, param[equals + 1 ..], " \t"),
        ) orelse 0;
        break;
    }

    return .{
        .type = split.type,
        .subtype = split.subtype,
        .weight = weight,
    };
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
    // An empty field value accepts anything, matching `accepts`.
    try std.testing.expectEqualStrings(
        "application/json",
        preferred("", &candidates).?,
    );
    try std.testing.expectEqualStrings(
        "application/json",
        preferred(" \t ", &candidates).?,
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

test "accept preferred matches the per-candidate scan above the range cap" {
    const candidates = [_][]const u8{
        "application/json",
        "text/html",
    };
    // Seventeen ranges force the fallback path; the last range is the match.
    const header = "a/a, b/b, c/c, d/d, e/e, f/f, g/g, h/h, i/i, j/j, " ++
        "k/k, l/l, m/m, n/n, o/o, p/p, text/html;q=0.7";
    try std.testing.expectEqualStrings(
        "text/html",
        preferred(header, &candidates).?,
    );
}

test "accept parsing is total for arbitrary headers" {
    var prng = std.Random.DefaultPrng.init(0xacce_99);
    const random = prng.random();

    const candidates = [_][]const u8{
        "application/json",
        "text/html",
        "image/png",
    };
    var buffer: [64]u8 = undefined;
    for (0..500) |_| {
        const length = random.intRangeAtMost(usize, 0, buffer.len);
        random.bytes(buffer[0..length]);
        const header = buffer[0..length];
        _ = accepts(header, "application/json");
        _ = accepts(header, candidates[random.intRangeLessThan(usize, 0, 3)]);
        _ = preferred(header, &candidates);
        _ = qualityFor(header, "text/html");
    }
}
