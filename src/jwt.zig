const std = @import("std");

/// Supported JSON Web Signature algorithms.
///
/// `hs256` uses a shared secret. `eddsa` uses Ed25519. RSA/ECDSA algorithms
/// are intentionally absent: they need a big-integer verifier outside the
/// current dependency surface.
pub const Algorithm = enum {
    hs256,
    eddsa,

    pub fn name(self: Algorithm) []const u8 {
        return switch (self) {
            .hs256 => "HS256",
            .eddsa => "EdDSA",
        };
    }
};

pub const SigningKey = union(Algorithm) {
    hs256: []const u8,
    eddsa: std.crypto.sign.Ed25519.KeyPair,
};

pub const VerifyingKey = union(Algorithm) {
    hs256: []const u8,
    eddsa: std.crypto.sign.Ed25519.PublicKey,
};

pub const EncodeOptions = struct {
    algorithm: Algorithm = .hs256,
    key: SigningKey,
    /// Optional `kid` header for key rotation.
    kid: ?[]const u8 = null,
    typ: ?[]const u8 = "JWT",
};

pub const VerifyOptions = struct {
    algorithm: Algorithm = .hs256,
    key: VerifyingKey,
    /// Clock skew allowance applied to `exp` and `nbf`.
    leeway_seconds: u32 = 0,
    issuer: ?[]const u8 = null,
    audience: ?[]const u8 = null,
    require_expiration: bool = true,
    require_subject: bool = false,
    /// Injected time for tests. When null, `io` supplies the real clock.
    now_seconds: ?i64 = null,
    /// Runtime seam used only when `now_seconds` is null.
    io: ?std.Io = null,
};

pub const Header = struct {
    algorithm: Algorithm,
    typ: ?[]const u8 = null,
    kid: ?[]const u8 = null,
};

/// A verified token. The arena owns the decoded header, payload, and claims.
pub const Verified = struct {
    arena: std.heap.ArenaAllocator,
    header: Header,
    payload: []const u8,
    claims: std.json.Value,

    pub fn deinit(self: *Verified) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn claim(self: *const Verified, name: []const u8) ?std.json.Value {
        return switch (self.claims) {
            .object => |object| object.get(name),
            else => null,
        };
    }

    pub fn claimString(self: *const Verified, name: []const u8) ?[]const u8 {
        return switch (self.claim(name) orelse return null) {
            .string => |value| value,
            else => null,
        };
    }

    pub fn claimInt(self: *const Verified, name: []const u8) ?i64 {
        return switch (self.claim(name) orelse return null) {
            .integer => |value| value,
            else => null,
        };
    }
};

const HeaderJson = struct {
    alg: []const u8,
    typ: ?[]const u8 = null,
    kid: ?[]const u8 = null,
};

/// Sign `claims` (any JSON-serializable value) into a compact JWS token.
pub fn encode(
    allocator: std.mem.Allocator,
    claims: anytype,
    options: EncodeOptions,
) ![]u8 {
    try requireSigningKey(options.algorithm, options.key);

    var header_writer = std.Io.Writer.Allocating.init(allocator);
    defer header_writer.deinit();
    try std.json.Stringify.value(
        HeaderJson{
            .alg = options.algorithm.name(),
            .typ = options.typ,
            .kid = options.kid,
        },
        .{ .emit_null_optional_fields = false },
        &header_writer.writer,
    );

    var payload_writer = std.Io.Writer.Allocating.init(allocator);
    defer payload_writer.deinit();
    try std.json.Stringify.value(claims, .{}, &payload_writer.writer);

    return encodePayload(
        allocator,
        header_writer.written(),
        payload_writer.written(),
        options,
    );
}

/// Sign a caller-supplied JSON payload without re-serializing it.
pub fn encodePayload(
    allocator: std.mem.Allocator,
    header_json: []const u8,
    payload_json: []const u8,
    options: EncodeOptions,
) ![]u8 {
    try requireSigningKey(options.algorithm, options.key);
    const header_b64 = try encodeBase64Alloc(allocator, header_json);
    defer allocator.free(header_b64);
    const payload_b64 = try encodeBase64Alloc(allocator, payload_json);
    defer allocator.free(payload_b64);
    const signing_input = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ header_b64, payload_b64 },
    );
    defer allocator.free(signing_input);

    var signature_storage: [64]u8 = undefined;
    const signature = switch (options.algorithm) {
        .hs256 => blk: {
            var mac: [32]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha256.create(
                &mac,
                signing_input,
                options.key.hs256,
            );
            @memcpy(signature_storage[0..mac.len], &mac);
            break :blk signature_storage[0..mac.len];
        },
        .eddsa => blk: {
            const signature = try options.key.eddsa.sign(signing_input, null);
            const bytes = signature.toBytes();
            @memcpy(signature_storage[0..bytes.len], &bytes);
            break :blk signature_storage[0..bytes.len];
        },
    };
    const signature_b64 = try encodeBase64Alloc(allocator, signature);
    defer allocator.free(signature_b64);

    return std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ signing_input, signature_b64 },
    );
}

/// Verify a compact JWS token and validate its standard claims.
pub fn verify(
    allocator: std.mem.Allocator,
    token: []const u8,
    options: VerifyOptions,
) !Verified {
    var parts = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts.next() orelse return error.MalformedToken;
    const payload_b64 = parts.next() orelse return error.MalformedToken;
    const signature_b64 = parts.next() orelse return error.MalformedToken;
    if (parts.next() != null) return error.MalformedToken;
    if (header_b64.len == 0 or payload_b64.len == 0 or
        signature_b64.len == 0)
    {
        return error.MalformedToken;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const header_bytes = decodeBase64Alloc(arena_allocator, header_b64) catch
        return error.InvalidHeader;
    const header_json = std.json.parseFromSliceLeaky(
        HeaderJson,
        arena_allocator,
        header_bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidHeader;
    const algorithm = parseAlgorithm(header_json.alg) orelse
        return error.UnsupportedAlgorithm;
    if (algorithm != options.algorithm) return error.AlgorithmMismatch;
    try requireVerifyingKey(algorithm, options.key);

    const signing_input = try std.fmt.allocPrint(
        arena_allocator,
        "{s}.{s}",
        .{ header_b64, payload_b64 },
    );
    try verifySignature(arena_allocator, signing_input, signature_b64, options);

    const payload_bytes = decodeBase64Alloc(arena_allocator, payload_b64) catch
        return error.InvalidClaims;
    const claims = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_allocator,
        payload_bytes,
        .{},
    ) catch return error.InvalidClaims;
    switch (claims) {
        .object => {},
        else => return error.InvalidClaims,
    }
    try validateClaims(claims, options);

    return .{
        .arena = arena,
        .header = .{
            .algorithm = algorithm,
            .typ = header_json.typ,
            .kid = header_json.kid,
        },
        .payload = payload_bytes,
        .claims = claims,
    };
}

fn verifySignature(
    allocator: std.mem.Allocator,
    signing_input: []const u8,
    signature_b64: []const u8,
    options: VerifyOptions,
) !void {
    _ = allocator;
    switch (options.algorithm) {
        .hs256 => {
            var signature: [32]u8 = undefined;
            decodeBase64Into(&signature, signature_b64) catch
                return error.InvalidSignature;
            var expected: [32]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha256.create(
                &expected,
                signing_input,
                options.key.hs256,
            );
            if (!std.crypto.timing_safe.eql([32]u8, expected, signature)) {
                return error.InvalidSignature;
            }
        },
        .eddsa => {
            var signature_bytes: [64]u8 = undefined;
            decodeBase64Into(&signature_bytes, signature_b64) catch
                return error.InvalidSignature;
            const signature = std.crypto.sign.Ed25519.Signature.fromBytes(
                signature_bytes,
            );
            signature.verify(signing_input, options.key.eddsa) catch
                return error.InvalidSignature;
        },
    }
}

fn validateClaims(claims: std.json.Value, options: VerifyOptions) !void {
    const object = claims.object;
    const now = options.now_seconds orelse blk: {
        const io = options.io orelse return error.ClockRequired;
        const timestamp = std.Io.Timestamp.now(io, .real);
        break :blk @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    };
    const leeway = @as(i64, @intCast(options.leeway_seconds));

    if (try integerClaim(object, "exp")) |expiration| {
        if (now - leeway >= expiration) return error.TokenExpired;
    } else if (options.require_expiration) {
        return error.MissingExpiration;
    }
    if (try integerClaim(object, "nbf")) |not_before| {
        if (now + leeway < not_before) return error.TokenNotYetValid;
    }
    if (options.issuer) |issuer| {
        const actual = try stringClaim(object, "iss") orelse
            return error.InvalidIssuer;
        if (!std.mem.eql(u8, actual, issuer)) return error.InvalidIssuer;
    }
    if (options.audience) |audience| {
        if (!audienceMatches(object.get("aud"), audience)) {
            return error.InvalidAudience;
        }
    }
    if (options.require_subject) {
        _ = try stringClaim(object, "sub") orelse
            return error.MissingSubject;
    }
}

fn integerClaim(
    object: std.json.ObjectMap,
    name: []const u8,
) !?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| blk: {
            if (!std.math.isFinite(float) or
                @trunc(float) != float or
                float < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                float > @as(f64, @floatFromInt(std.math.maxInt(i64))))
            {
                return error.InvalidClaims;
            }
            break :blk @intFromFloat(float);
        },
        else => error.InvalidClaims,
    };
}

fn stringClaim(
    object: std.json.ObjectMap,
    name: []const u8,
) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidClaims,
    };
}

fn audienceMatches(value: ?std.json.Value, expected: []const u8) bool {
    const audience = value orelse return false;
    return switch (audience) {
        .string => |string| std.mem.eql(u8, string, expected),
        .array => |items| blk: {
            for (items.items) |item| {
                switch (item) {
                    .string => |string| if (std.mem.eql(
                        u8,
                        string,
                        expected,
                    )) break :blk true,
                    else => {},
                }
            }
            break :blk false;
        },
        else => false,
    };
}

fn parseAlgorithm(raw: []const u8) ?Algorithm {
    if (std.mem.eql(u8, raw, "HS256")) return .hs256;
    if (std.mem.eql(u8, raw, "EdDSA")) return .eddsa;
    return null;
}

fn requireSigningKey(algorithm: Algorithm, key: SigningKey) !void {
    if (std.meta.activeTag(key) != algorithm) return error.KeyAlgorithmMismatch;
    switch (key) {
        .hs256 => |secret| if (secret.len < 32) return error.WeakKey,
        .eddsa => {},
    }
}

fn requireVerifyingKey(algorithm: Algorithm, key: VerifyingKey) !void {
    if (std.meta.activeTag(key) != algorithm) return error.KeyAlgorithmMismatch;
    switch (key) {
        .hs256 => |secret| if (secret.len < 32) return error.WeakKey,
        .eddsa => {},
    }
}

fn encodeBase64Alloc(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]const u8 {
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(source.len);
    const output = try allocator.alloc(u8, size);
    return std.base64.url_safe_no_pad.Encoder.encode(output, source);
}

fn decodeBase64Alloc(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]u8 {
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(source) catch
        return error.InvalidBase64;
    const output = try allocator.alloc(u8, size);
    std.base64.url_safe_no_pad.Decoder.decode(output, source) catch
        return error.InvalidBase64;
    return output;
}

fn decodeBase64Into(destination: []u8, source: []const u8) !void {
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(source) catch
        return error.InvalidBase64;
    if (size != destination.len) return error.InvalidBase64;
    std.base64.url_safe_no_pad.Decoder.decode(destination, source) catch
        return error.InvalidBase64;
}

test "jwt HS256 round trip validates standard claims" {
    const allocator = std.testing.allocator;
    const key = "0123456789abcdef0123456789abcdef";
    const token = try encode(
        allocator,
        .{
            .sub = "user-42",
            .iss = "weft",
            .aud = "tests",
            .exp = @as(i64, 2_000_000_000),
            .nbf = @as(i64, 1_900_000_000),
            .role = "admin",
        },
        .{ .key = .{ .hs256 = key } },
    );
    defer allocator.free(token);

    var verified = try verify(allocator, token, .{
        .key = .{ .hs256 = key },
        .issuer = "weft",
        .audience = "tests",
        .now_seconds = 1_950_000_000,
    });
    defer verified.deinit();
    try std.testing.expectEqualStrings("user-42", verified.claimString("sub").?);
    try std.testing.expectEqualStrings("admin", verified.claimString("role").?);
    try std.testing.expectEqual(@as(i64, 2_000_000_000), verified.claimInt("exp").?);
    try std.testing.expectEqual(Algorithm.hs256, verified.header.algorithm);
}

test "jwt rejects tampering, expiry, and algorithm confusion" {
    const allocator = std.testing.allocator;
    const key = "0123456789abcdef0123456789abcdef";
    const token = try encode(
        allocator,
        .{ .sub = "user-42", .exp = @as(i64, 100) },
        .{ .key = .{ .hs256 = key } },
    );
    defer allocator.free(token);

    try std.testing.expectError(
        error.TokenExpired,
        verify(allocator, token, .{
            .key = .{ .hs256 = key },
            .now_seconds = 101,
        }),
    );

    var tampered = try allocator.dupe(u8, token);
    defer allocator.free(tampered);
    tampered[tampered.len - 1] = if (tampered[tampered.len - 1] == 'A') 'B' else 'A';
    try std.testing.expectError(
        error.InvalidSignature,
        verify(allocator, tampered, .{
            .key = .{ .hs256 = key },
            .now_seconds = 50,
        }),
    );

    try std.testing.expectError(
        error.AlgorithmMismatch,
        verify(allocator, token, .{
            .algorithm = .eddsa,
            .key = .{ .eddsa = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io).public_key },
            .now_seconds = 50,
        }),
    );
}

test "jwt EdDSA round trip" {
    const allocator = std.testing.allocator;
    const key_pair = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io);
    const token = try encode(
        allocator,
        .{ .sub = "eddsa-user", .exp = @as(i64, 2_000_000_000) },
        .{ .algorithm = .eddsa, .key = .{ .eddsa = key_pair } },
    );
    defer allocator.free(token);

    var verified = try verify(allocator, token, .{
        .algorithm = .eddsa,
        .key = .{ .eddsa = key_pair.public_key },
        .now_seconds = 1_950_000_000,
    });
    defer verified.deinit();
    try std.testing.expectEqualStrings(
        "eddsa-user",
        verified.claimString("sub").?,
    );
    try std.testing.expectEqual(Algorithm.eddsa, verified.header.algorithm);
}
