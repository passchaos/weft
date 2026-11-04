const std = @import("std");

/// Conditional request fields relevant to a `GET`/`HEAD` representation.
pub const Fields = struct {
    if_match: ?[]const u8 = null,
    if_none_match: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,
    if_unmodified_since: ?[]const u8 = null,
    if_range: ?[]const u8 = null,
    range: ?[]const u8 = null,
};

pub const Outcome = enum {
    proceed,
    not_modified,
    precondition_failed,
};

pub const Result = struct {
    outcome: Outcome = .proceed,
    /// False when `If-Range` rejects the current representation, in which case
    /// the caller must ignore `Range` and send the full response.
    range_allowed: bool = true,
};

/// Evaluate RFC 9110 §13.2.2 preconditions for `GET`/`HEAD`.
///
/// `etag` is a strong entity tag and `last_modified` is the representation's
/// modification time in Unix seconds.
pub fn evaluate(fields: Fields, etag: []const u8, last_modified: i64) Result {
    if (fields.if_match) |value| {
        if (!strongMatches(value, etag)) {
            return .{ .outcome = .precondition_failed };
        }
    } else if (fields.if_unmodified_since) |value| {
        if (parseDate(value)) |date| {
            if (last_modified > date) {
                return .{ .outcome = .precondition_failed };
            }
        }
    }

    if (fields.if_none_match) |value| {
        if (weakMatches(value, etag)) {
            return .{ .outcome = .not_modified };
        }
    } else if (fields.if_modified_since) |value| {
        if (parseDate(value)) |date| {
            if (last_modified <= date) {
                return .{ .outcome = .not_modified };
            }
        }
    }

    var result = Result{};
    if (fields.range != null) {
        if (fields.if_range) |value| {
            result.range_allowed = ifRangeMatches(value, etag, last_modified);
        }
    }
    return result;
}

fn ifRangeMatches(value: []const u8, etag: []const u8, last_modified: i64) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '"' or std.ascii.startsWithIgnoreCase(trimmed, "W/")) {
        return strongMatches(trimmed, etag);
    }
    if (parseDate(trimmed)) |date| {
        // RFC 9110 §13.1.5: an If-Range date matches only when it is exactly
        // equal to the representation's Last-Modified value.
        return last_modified == date;
    }
    return false;
}

/// Strong comparison: both tags must be strong and byte-identical.
pub fn strongMatches(header: []const u8, etag: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, header, ',');
    while (iterator.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, token, "*")) return true;
        if (std.ascii.startsWithIgnoreCase(token, "W/")) continue;
        if (std.mem.eql(u8, token, etag)) return true;
    }
    return false;
}

/// Weak comparison: opaque tags match even when either side is weak.
pub fn weakMatches(header: []const u8, etag: []const u8) bool {
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

pub const value_len: usize = 29;
const latest_unix_second: i64 = 253_402_300_799;

/// Render a Unix timestamp as an IMF-fixdate, e.g.
/// `Sun, 06 Nov 1994 08:49:37 GMT`.
pub fn formatDate(unix_second: i64) [value_len]u8 {
    const clamped: u64 = @intCast(std.math.clamp(
        unix_second,
        0,
        latest_unix_second,
    ));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = clamped };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const weekdays = [_]*const [3]u8{
        "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
    };
    const months = [_]*const [3]u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    var value = "Thu, 01 Jan 1970 00:00:00 GMT".*;
    const weekday_index: usize = @intCast((epoch_day.day + 4) % weekdays.len);
    @memcpy(value[0..3], weekdays[weekday_index]);
    writeTwoDigits(value[5..7], month_day.day_index + 1);
    @memcpy(value[8..11], months[@intFromEnum(month_day.month) - 1]);
    writeFourDigits(value[12..16], year_day.year);
    writeTwoDigits(value[17..19], day_seconds.getHoursIntoDay());
    writeTwoDigits(value[20..22], day_seconds.getMinutesIntoHour());
    writeTwoDigits(value[23..25], day_seconds.getSecondsIntoMinute());
    return value;
}

/// Parse any of the three HTTP-date formats required by RFC 9110 §5.6.7.
/// Returns Unix seconds, or null when the value is malformed.
pub fn parseDate(text: []const u8) ?i64 {
    const value = std.mem.trim(u8, text, " \t");
    if (value.len == 0) return null;

    var tokens: [8][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, value, " \t");
    while (iterator.next()) |token| {
        if (count == tokens.len) return null;
        tokens[count] = token;
        count += 1;
    }

    // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT
    if (count == 6 and hasComma(tokens[0])) {
        if (!std.ascii.eqlIgnoreCase(tokens[5], "GMT")) return null;
        return composeDate(
            parseYear(tokens[3]),
            monthFromName(tokens[2]),
            parseNumber(tokens[1]),
            parseTime(tokens[4]),
        );
    }

    // RFC 850: Sunday, 06-Nov-94 08:49:37 GMT
    if (count == 4 and hasComma(tokens[0])) {
        if (!std.ascii.eqlIgnoreCase(tokens[3], "GMT")) return null;
        var parts = std.mem.splitScalar(u8, tokens[1], '-');
        const day = parts.next() orelse return null;
        const month = parts.next() orelse return null;
        const year = parts.next() orelse return null;
        if (parts.next() != null) return null;
        const short_year = parseYear(year) orelse return null;
        const expanded = if (year.len <= 2)
            (if (short_year < 70) short_year + 2000 else short_year + 1900)
        else
            short_year;
        return composeDate(
            expanded,
            monthFromName(month),
            parseNumber(day),
            parseTime(tokens[2]),
        );
    }

    // asctime: Sun Nov  6 08:49:37 1994
    if (count == 5 and !hasComma(tokens[0])) {
        return composeDate(
            parseYear(tokens[4]),
            monthFromName(tokens[1]),
            parseNumber(tokens[2]),
            parseTime(tokens[3]),
        );
    }
    return null;
}

fn hasComma(token: []const u8) bool {
    return token.len > 0 and token[token.len - 1] == ',';
}

fn parseYear(text: []const u8) ?i64 {
    if (text.len < 2 or text.len > 4) return null;
    for (text) |char| {
        if (char < '0' or char > '9') return null;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn parseNumber(text: []const u8) ?i64 {
    if (text.len == 0 or text.len > 2) return null;
    for (text) |char| {
        if (char < '0' or char > '9') return null;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn parseTime(text: []const u8) ?i64 {
    var parts = std.mem.splitScalar(u8, text, ':');
    const hour = parseNumber(parts.next() orelse return null) orelse return null;
    const minute = parseNumber(parts.next() orelse return null) orelse return null;
    const second = parseNumber(parts.next() orelse return null) orelse return null;
    if (parts.next() != null) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;
    return hour * 3600 + minute * 60 + second;
}

fn monthFromName(text: []const u8) ?i64 {
    if (text.len != 3) return null;
    const months = [_]*const [3]u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (months, 0..) |name, index| {
        if (std.ascii.eqlIgnoreCase(text, name)) return @intCast(index + 1);
    }
    return null;
}

fn composeDate(
    year: ?i64,
    month: ?i64,
    day: ?i64,
    seconds: ?i64,
) ?i64 {
    const y = year orelse return null;
    const m = month orelse return null;
    const d = day orelse return null;
    const s = seconds orelse return null;
    if (y < 1900 or y > 9999) return null;
    if (m < 1 or m > 12) return null;
    if (d < 1 or d > daysInMonth(y, m)) return null;
    return daysFromCivil(y, m, d) * 86400 + s;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or
        @mod(year, 400) == 0;
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const adjusted_year = if (month <= 2) year - 1 else year;
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const month_prime = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn writeTwoDigits(destination: *[2]u8, value: anytype) void {
    const number: u8 = @intCast(value);
    destination[0] = '0' + number / 10;
    destination[1] = '0' + number % 10;
}

fn writeFourDigits(destination: *[4]u8, value: anytype) void {
    const number: u16 = @intCast(value);
    destination[0] = '0' + @as(u8, @intCast(number / 1000));
    destination[1] = '0' + @as(u8, @intCast(number / 100 % 10));
    destination[2] = '0' + @as(u8, @intCast(number / 10 % 10));
    destination[3] = '0' + @as(u8, @intCast(number % 10));
}

test "precondition formats and parses IMF-fixdate" {
    const rendered = formatDate(784_111_777);
    try std.testing.expectEqualStrings(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        &rendered,
    );
    try std.testing.expectEqual(
        @as(?i64, 784_111_777),
        parseDate(&rendered),
    );
    try std.testing.expectEqualStrings(
        "Thu, 01 Jan 1970 00:00:00 GMT",
        &formatDate(0),
    );
    try std.testing.expectEqualStrings(
        "Tue, 29 Feb 2000 00:00:00 GMT",
        &formatDate(951_782_400),
    );
}

test "precondition parses legacy HTTP-date formats" {
    // RFC 850
    try std.testing.expectEqual(
        @as(?i64, 784_111_777),
        parseDate("Sunday, 06-Nov-94 08:49:37 GMT"),
    );
    // asctime
    try std.testing.expectEqual(
        @as(?i64, 784_111_777),
        parseDate("Sun Nov  6 08:49:37 1994"),
    );
    try std.testing.expect(parseDate("Sun, 31 Feb 1994 08:49:37 GMT") == null);
    try std.testing.expect(parseDate("Sun, 06 Nov 1994 25:49:37 GMT") == null);
    try std.testing.expect(parseDate("not a date") == null);
    try std.testing.expect(parseDate("") == null);
}

test "precondition evaluates If-Match before If-None-Match" {
    const etag = "\"abc\"";
    try std.testing.expectEqual(
        Outcome.precondition_failed,
        evaluate(.{ .if_match = "\"other\"" }, etag, 100).outcome,
    );
    try std.testing.expectEqual(
        Outcome.proceed,
        evaluate(.{ .if_match = "*" }, etag, 100).outcome,
    );
    // Weak validators never satisfy the strong If-Match comparison.
    try std.testing.expectEqual(
        Outcome.precondition_failed,
        evaluate(.{ .if_match = "W/\"abc\"" }, etag, 100).outcome,
    );
    try std.testing.expectEqual(
        Outcome.not_modified,
        evaluate(.{ .if_none_match = "W/\"abc\"" }, etag, 100).outcome,
    );
}

test "precondition evaluates date validators" {
    const etag = "\"abc\"";
    const modified = parseDate("Sun, 06 Nov 1994 08:49:37 GMT").?;
    try std.testing.expectEqual(
        Outcome.not_modified,
        evaluate(
            .{ .if_modified_since = "Sun, 06 Nov 1994 08:49:37 GMT" },
            etag,
            modified,
        ).outcome,
    );
    try std.testing.expectEqual(
        Outcome.proceed,
        evaluate(
            .{ .if_modified_since = "Sun, 06 Nov 1994 08:49:36 GMT" },
            etag,
            modified,
        ).outcome,
    );
    try std.testing.expectEqual(
        Outcome.precondition_failed,
        evaluate(
            .{ .if_unmodified_since = "Sun, 06 Nov 1994 08:49:36 GMT" },
            etag,
            modified,
        ).outcome,
    );
    // If-None-Match takes precedence over If-Modified-Since.
    try std.testing.expectEqual(
        Outcome.proceed,
        evaluate(.{
            .if_none_match = "\"other\"",
            .if_modified_since = "Sun, 06 Nov 1994 08:49:37 GMT",
        }, etag, modified).outcome,
    );
}

test "precondition gates If-Range on the current validator" {
    const etag = "\"abc\"";
    const modified = parseDate("Sun, 06 Nov 1994 08:49:37 GMT").?;
    try std.testing.expect(evaluate(.{}, etag, modified).range_allowed);
    try std.testing.expect(evaluate(.{
        .range = "bytes=0-1",
        .if_range = "\"abc\"",
    }, etag, modified).range_allowed);
    try std.testing.expect(!evaluate(.{
        .range = "bytes=0-1",
        .if_range = "\"other\"",
    }, etag, modified).range_allowed);
    try std.testing.expect(!evaluate(.{
        .range = "bytes=0-1",
        .if_range = "W/\"abc\"",
    }, etag, modified).range_allowed);
    try std.testing.expect(evaluate(.{
        .range = "bytes=0-1",
        .if_range = "Sun, 06 Nov 1994 08:49:37 GMT",
    }, etag, modified).range_allowed);
    try std.testing.expect(!evaluate(.{
        .range = "bytes=0-1",
        .if_range = "Sun, 06 Nov 1994 08:49:36 GMT",
    }, etag, modified).range_allowed);
    // A newer date is not the current representation's validator.
    try std.testing.expect(!evaluate(.{
        .range = "bytes=0-1",
        .if_range = "Sun, 06 Nov 1994 08:49:38 GMT",
    }, etag, modified).range_allowed);
    // If-Range is ignored when there is no Range request.
    try std.testing.expect(evaluate(.{
        .if_range = "\"other\"",
    }, etag, modified).range_allowed);
}

test "date parsing and precondition evaluation are total for arbitrary input" {
    var prng = std.Random.DefaultPrng.init(0xda7e_42);
    const random = prng.random();
    var buffer: [48]u8 = undefined;
    for (0..500) |_| {
        const length = random.intRangeAtMost(usize, 0, buffer.len);
        random.bytes(buffer[0..length]);
        const text = buffer[0..length];
        _ = parseDate(text);
        _ = evaluate(.{
            .if_match = text,
            .if_none_match = text,
            .if_modified_since = text,
            .if_unmodified_since = text,
            .if_range = text,
            .range = text,
        }, "\"tag\"", 1_700_000_000);
    }
}
