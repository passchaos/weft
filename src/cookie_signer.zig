const std = @import("std");

/// HMAC-SHA256 cookie signer.
///
/// Signed values use `value.signature`, where the signature is unpadded
/// Base64URL. The value itself must already be a valid cookie value; use
/// `weft.cookie.SetCookie` validation before writing the signed result.
pub const Signer = struct {
    key: []const u8,

    pub fn init(key: []const u8) !Signer {
        if (key.len < 32) return error.WeakKey;
        return .{ .key = key };
    }

    pub fn sign(
        self: Signer,
        allocator: std.mem.Allocator,
        value: []const u8,
    ) ![]u8 {
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, value, self.key);
        const encoded_size = std.base64.url_safe_no_pad.Encoder.calcSize(
            mac.len,
        );
        const signature = try allocator.alloc(u8, encoded_size);
        defer allocator.free(signature);
        const encoded = std.base64.url_safe_no_pad.Encoder.encode(
            signature,
            &mac,
        );
        return std.fmt.allocPrint(
            allocator,
            "{s}.{s}",
            .{ value, encoded },
        );
    }

    /// Return the unsigned value when the signature is valid.
    pub fn verify(self: Signer, signed: []const u8) ?[]const u8 {
        const separator = std.mem.lastIndexOfScalar(u8, signed, '.') orelse
            return null;
        const value = signed[0..separator];
        const signature_b64 = signed[separator + 1 ..];
        var signature: [32]u8 = undefined;
        const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(
            signature_b64,
        ) catch return null;
        if (size != signature.len) return null;
        std.base64.url_safe_no_pad.Decoder.decode(
            &signature,
            signature_b64,
        ) catch return null;
        var expected: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, value, self.key);
        if (!std.crypto.timing_safe.eql([32]u8, expected, signature)) {
            return null;
        }
        return value;
    }
};

test "cookie signer round trips and rejects tampering" {
    const allocator = std.testing.allocator;
    const key = "0123456789abcdef0123456789abcdef";
    const signer = try Signer.init(key);
    const signed = try signer.sign(allocator, "session-42");
    defer allocator.free(signed);

    try std.testing.expectEqualStrings(
        "session-42",
        signer.verify(signed).?,
    );

    var tampered = try allocator.dupe(u8, signed);
    defer allocator.free(tampered);
    tampered[0] = 'S';
    try std.testing.expect(signer.verify(tampered) == null);

    const other = try Signer.init("abcdef0123456789abcdef0123456789");
    try std.testing.expect(other.verify(signed) == null);
    try std.testing.expectError(error.WeakKey, Signer.init("short"));
}
