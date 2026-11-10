const std = @import("std");
const quality_mod = @import("../quality.zig");

/// Encodings are listed in descending preference so equal `q` values resolve
/// to `br` first, then `zstd`, then `gzip`.
pub const Variant = struct {
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
pub fn chooseVariant(header: ?[]const u8) ?Variant {
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
pub fn parseQuality(text: []const u8) ?u16 {
    return quality_mod.parse(std.mem.trim(u8, text, " \t"));
}

pub fn sidecarIsFresh(
    source: std.Io.Timestamp,
    sidecar: std.Io.Timestamp,
    check: bool,
) bool {
    if (!check) return true;
    return sidecar.nanoseconds >= source.nanoseconds;
}
