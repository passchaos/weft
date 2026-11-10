const std = @import("std");

pub const max_ranges = 16;

pub const RangePart = struct {
    start: usize,
    length: usize,
};

pub const RangeSet = struct {
    parts: [max_ranges]RangePart = undefined,
    count: usize = 0,
};

pub const Range = union(enum) {
    ignore,
    unsatisfiable,
    ranges: RangeSet,
};

const ParsedRange = union(enum) {
    ignore,
    unsatisfiable,
    range: RangePart,
};

pub fn parseRange(header: []const u8, size: usize) Range {
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
