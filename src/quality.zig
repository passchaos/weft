const std = @import("std");

/// Parse an HTTP `q` value into thousandths (`0.5` becomes `500`).
///
/// Only the RFC 9110 qvalue grammar is accepted: `0` or `1`, optionally
/// followed by a dot and up to three digits. A `1` integer part requires a
/// zero fraction. Malformed values return null.
pub fn parse(text: []const u8) ?u16 {
    if (text.len == 0) return null;
    if (text[0] != '0' and text[0] != '1') return null;
    const whole: u16 = text[0] - '0';
    if (text.len == 1) return whole * 1000;
    if (text[1] != '.') return null;

    var fraction: u16 = 0;
    var digits: usize = 0;
    var index: usize = 2;
    while (index < text.len) : (index += 1) {
        const char = text[index];
        if (char < '0' or char > '9') return null;
        if (digits == 3) return null;
        fraction = fraction * 10 + (char - '0');
        digits += 1;
    }
    while (digits < 3) : (digits += 1) fraction *= 10;
    if (whole == 1 and fraction != 0) return null;
    return whole * 1000 + fraction;
}

test "quality parses RFC qvalues into thousandths" {
    try std.testing.expectEqual(@as(?u16, 1000), parse("1"));
    try std.testing.expectEqual(@as(?u16, 1000), parse("1.000"));
    try std.testing.expectEqual(@as(?u16, 500), parse("0.5"));
    try std.testing.expectEqual(@as(?u16, 50), parse("0.05"));
    try std.testing.expectEqual(@as(?u16, 0), parse("0"));
    try std.testing.expectEqual(@as(?u16, 0), parse("0."));
    try std.testing.expect(parse("1.5") == null);
    try std.testing.expect(parse("2") == null);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("abc") == null);
    try std.testing.expect(parse("0.1234") == null);
    try std.testing.expect(parse(".5") == null);
    try std.testing.expect(parse("00.5") == null);
}
