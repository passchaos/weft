const std = @import("std");
const vail = @import("vail");

/// Supported JSON Web Signature algorithms.
///
/// `hs256` uses a shared secret. `eddsa` uses Ed25519. RSA/ECDSA algorithms
/// are intentionally absent: they need a big-integer verifier outside the
/// current dependency surface.
pub const Algorithm = enum {
    hs256,
    rs256,
    es256,
    eddsa,

    pub fn name(self: Algorithm) []const u8 {
        return switch (self) {
            .hs256 => "HS256",
            .rs256 => "RS256",
            .es256 => "ES256",
            .eddsa => "EdDSA",
        };
    }
};

pub const SigningKey = union(enum) {
    hs256: []const u8,
    eddsa: std.crypto.sign.Ed25519.KeyPair,
};

pub const VerifyingKey = union(Algorithm) {
    hs256: []const u8,
    /// RSA-2048 with exponent 65537, the shape supported by vail's verifier.
    rs256: vail.crypto.rsa.PreparedPublicKey,
    es256: std.crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey,
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

/// One verification key from a JSON Web Key Set.
pub const Jwk = struct {
    kid: ?[]const u8,
    algorithm: Algorithm,
    key: VerifyingKey,
};

/// Parsed JWKS document. Keys borrow the set's arena.
pub const KeySet = struct {
    arena: std.heap.ArenaAllocator,
    keys: []const Jwk,

    pub fn parse(
        allocator: std.mem.Allocator,
        json_bytes: []const u8,
    ) !KeySet {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const root = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena_allocator,
            json_bytes,
            .{},
        ) catch return error.InvalidJwks;
        const object = switch (root) {
            .object => |value| value,
            else => return error.InvalidJwks,
        };
        const keys_value = object.get("keys") orelse return error.InvalidJwks;
        const array = switch (keys_value) {
            .array => |value| value,
            else => return error.InvalidJwks,
        };

        var list: std.ArrayListUnmanaged(Jwk) = .empty;
        for (array.items) |item| {
            const key_object = switch (item) {
                .object => |value| value,
                else => continue,
            };
            const kty = jsonString(key_object, "kty") orelse continue;
            const kid = jsonString(key_object, "kid");
            const declared_alg = jsonString(key_object, "alg");
            const algorithm = if (declared_alg) |name|
                parseAlgorithm(name) orelse continue
            else
                inferAlgorithm(kty) orelse continue;
            if (algorithm == .hs256) continue;

            const key: VerifyingKey = switch (algorithm) {
                .rs256 => blk: {
                    if (!std.mem.eql(u8, kty, "RSA")) continue;
                    const modulus = (try jsonBase64(
                        arena_allocator,
                        key_object,
                        "n",
                    )) orelse continue;
                    const exponent = (try jsonBase64(
                        arena_allocator,
                        key_object,
                        "e",
                    )) orelse continue;
                    break :blk .{
                        .rs256 = vail.crypto.rsa.PreparedPublicKey.init(
                            exponent,
                            modulus,
                        ) catch continue,
                    };
                },
                .es256 => blk: {
                    if (!std.mem.eql(u8, kty, "EC")) continue;
                    const curve = jsonString(key_object, "crv") orelse continue;
                    if (!std.mem.eql(u8, curve, "P-256")) continue;
                    const x = (try jsonBase64(
                        arena_allocator,
                        key_object,
                        "x",
                    )) orelse continue;
                    const y = (try jsonBase64(
                        arena_allocator,
                        key_object,
                        "y",
                    )) orelse continue;
                    if (x.len != 32 or y.len != 32) continue;
                    var sec1: [65]u8 = undefined;
                    sec1[0] = 4;
                    @memcpy(sec1[1..33], x);
                    @memcpy(sec1[33..65], y);
                    const public_key = std.crypto.sign.ecdsa
                        .EcdsaP256Sha256.PublicKey.fromSec1(&sec1) catch continue;
                    break :blk .{ .es256 = public_key };
                },
                .eddsa => blk: {
                    if (!std.mem.eql(u8, kty, "OKP")) continue;
                    const curve = jsonString(key_object, "crv") orelse continue;
                    if (!std.mem.eql(u8, curve, "Ed25519")) continue;
                    const x = (try jsonBase64(
                        arena_allocator,
                        key_object,
                        "x",
                    )) orelse continue;
                    if (x.len != 32) continue;
                    var bytes: [32]u8 = undefined;
                    @memcpy(&bytes, x);
                    const public_key = std.crypto.sign.Ed25519.PublicKey
                        .fromBytes(bytes) catch continue;
                    break :blk .{ .eddsa = public_key };
                },
                else => continue,
            };
            try list.append(arena_allocator, .{
                .kid = kid,
                .algorithm = algorithm,
                .key = key,
            });
        }
        return .{
            .arena = arena,
            .keys = try list.toOwnedSlice(arena_allocator),
        };
    }

    pub fn deinit(self: *KeySet) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(
        self: *const KeySet,
        kid: ?[]const u8,
        algorithm: Algorithm,
    ) ?*const Jwk {
        var fallback: ?*const Jwk = null;
        for (self.keys) |*key| {
            if (key.algorithm != algorithm) continue;
            if (kid) |wanted| {
                const actual = key.kid orelse continue;
                if (std.mem.eql(u8, actual, wanted)) return key;
                continue;
            }
            if (fallback != null) return null;
            fallback = key;
        }
        return if (kid == null) fallback else null;
    }

    pub fn verify(
        self: *const KeySet,
        allocator: std.mem.Allocator,
        token: []const u8,
        options: KeySetVerifyOptions,
    ) !Verified {
        var header_arena = std.heap.ArenaAllocator.init(allocator);
        defer header_arena.deinit();
        const header = try parseHeader(header_arena.allocator(), token);
        const key = self.find(header.kid, header.algorithm) orelse
            return error.UnknownKey;
        return verifyToken(allocator, token, .{
            .algorithm = header.algorithm,
            .key = key.key,
            .leeway_seconds = options.leeway_seconds,
            .issuer = options.issuer,
            .audience = options.audience,
            .require_expiration = options.require_expiration,
            .require_subject = options.require_subject,
            .now_seconds = options.now_seconds,
            .io = options.io,
        });
    }
};

pub const KeySetVerifyOptions = struct {
    leeway_seconds: u32 = 0,
    issuer: ?[]const u8 = null,
    audience: ?[]const u8 = null,
    require_expiration: bool = true,
    require_subject: bool = false,
    now_seconds: ?i64 = null,
    io: ?std.Io = null,
};

fn parseHeader(allocator: std.mem.Allocator, token: []const u8) !Header {
    const dot = std.mem.indexOfScalar(u8, token, '.') orelse
        return error.MalformedToken;
    const header_bytes = decodeBase64Alloc(allocator, token[0..dot]) catch
        return error.InvalidHeader;
    const header_json = std.json.parseFromSliceLeaky(
        HeaderJson,
        allocator,
        header_bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidHeader;
    const algorithm = parseAlgorithm(header_json.alg) orelse
        return error.UnsupportedAlgorithm;
    return .{
        .algorithm = algorithm,
        .typ = header_json.typ,
        .kid = header_json.kid,
    };
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonBase64(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) !?[]u8 {
    const raw = jsonString(object, name) orelse return null;
    return decodeBase64Alloc(allocator, raw) catch return error.InvalidJwks;
}

fn inferAlgorithm(kty: []const u8) ?Algorithm {
    if (std.mem.eql(u8, kty, "RSA")) return .rs256;
    if (std.mem.eql(u8, kty, "EC")) return .es256;
    if (std.mem.eql(u8, kty, "OKP")) return .eddsa;
    return null;
}

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
    switch (options.algorithm) {
        .hs256, .eddsa => {},
        else => return error.UnsupportedSigningAlgorithm,
    }
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
        .rs256, .es256 => unreachable,
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
pub const verify = verifyToken;

fn verifyToken(
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
        .rs256 => {
            const signature = decodeBase64Alloc(allocator, signature_b64) catch
                return error.InvalidSignature;
            defer allocator.free(signature);
            options.key.rs256.verifyPkcs1v15Sha256(
                &.{signing_input},
                signature,
            ) catch return error.InvalidSignature;
        },
        .es256 => {
            var signature_bytes: [64]u8 = undefined;
            decodeBase64Into(&signature_bytes, signature_b64) catch
                return error.InvalidSignature;
            const signature = std.crypto.sign.ecdsa.EcdsaP256Sha256.Signature
                .fromBytes(signature_bytes);
            signature.verify(signing_input, options.key.es256) catch
                return error.InvalidSignature;
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
    if (std.mem.eql(u8, raw, "RS256")) return .rs256;
    if (std.mem.eql(u8, raw, "ES256")) return .es256;
    if (std.mem.eql(u8, raw, "EdDSA")) return .eddsa;
    return null;
}

fn requireSigningKey(algorithm: Algorithm, key: SigningKey) !void {
    const matches = switch (key) {
        .hs256 => algorithm == .hs256,
        .eddsa => algorithm == .eddsa,
    };
    if (!matches) return error.KeyAlgorithmMismatch;
    switch (key) {
        .hs256 => |secret| if (secret.len < 32) return error.WeakKey,
        .eddsa => {},
    }
}

fn requireVerifyingKey(algorithm: Algorithm, key: VerifyingKey) !void {
    if (std.meta.activeTag(key) != algorithm) return error.KeyAlgorithmMismatch;
    switch (key) {
        .hs256 => |secret| if (secret.len < 32) return error.WeakKey,
        .rs256, .es256, .eddsa => {},
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

fn base64ForTest(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const output = try allocator.alloc(u8, size);
    return std.base64.url_safe_no_pad.Encoder.encode(output, bytes);
}

test "jwt ES256 and JWKS verification" {
    const allocator = std.testing.allocator;
    const key_pair = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(
        std.testing.io,
    );

    const header_b64 = try base64ForTest(
        allocator,
        "{\"alg\":\"ES256\",\"kid\":\"ec-1\"}",
    );
    defer allocator.free(header_b64);
    const payload_b64 = try base64ForTest(
        allocator,
        "{\"sub\":\"ec-user\",\"exp\":2000000000}",
    );
    defer allocator.free(payload_b64);
    const signing_input = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ header_b64, payload_b64 },
    );
    defer allocator.free(signing_input);
    const signature = try key_pair.sign(signing_input, null);
    const signature_bytes = signature.toBytes();
    const signature_b64 = try base64ForTest(allocator, &signature_bytes);
    defer allocator.free(signature_b64);
    const token = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ signing_input, signature_b64 },
    );
    defer allocator.free(token);

    var direct = try verify(allocator, token, .{
        .algorithm = .es256,
        .key = .{ .es256 = key_pair.public_key },
        .now_seconds = 1_900_000_000,
    });
    defer direct.deinit();
    try std.testing.expectEqualStrings("ec-user", direct.claimString("sub").?);

    const sec1 = key_pair.public_key.toUncompressedSec1();
    const x = try base64ForTest(allocator, sec1[1..33]);
    defer allocator.free(x);
    const y = try base64ForTest(allocator, sec1[33..65]);
    defer allocator.free(y);
    const jwks_json = try std.fmt.allocPrint(
        allocator,
        "{{\"keys\":[{{\"kty\":\"EC\",\"crv\":\"P-256\",\"kid\":\"ec-1\",\"alg\":\"ES256\",\"x\":\"{s}\",\"y\":\"{s}\"}}]}}",
        .{ x, y },
    );
    defer allocator.free(jwks_json);

    var set = try KeySet.parse(allocator, jwks_json);
    defer set.deinit();
    var verified = try set.verify(allocator, token, .{
        .now_seconds = 1_900_000_000,
    });
    defer verified.deinit();
    try std.testing.expectEqualStrings("ec-user", verified.claimString("sub").?);
    try std.testing.expectEqualStrings("ec-1", verified.header.kid.?);

    try std.testing.expect(set.find("other", .es256) == null);
}
