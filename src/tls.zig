const std = @import("std");
const netz = @import("netz");

pub const Identity = netz.tls.server_identity_file.Identity;

/// Atomically replaceable TLS server identity.
///
/// `provider()` plugs into `TlsListenOptions.identity_provider` (HTTP/1 and
/// HTTP/2). Each handshake borrows one generation; `reload` swaps the current
/// generation and frees the old one after its last in-flight handshake
/// releases it.
pub const ReloadableIdentity = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    current: *Generation,

    const Generation = struct {
        owner: *ReloadableIdentity,
        identity: Identity,
        references: usize = 0,
        retired: bool = false,
    };

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        identity: Identity,
    ) !ReloadableIdentity {
        const generation = try allocator.create(Generation);
        errdefer allocator.destroy(generation);
        generation.* = .{
            .owner = undefined,
            .identity = identity,
        };
        return .{
            .io = io,
            .allocator = allocator,
            .current = generation,
        };
    }

    /// Borrow the current identity for the listener's static placeholder.
    pub fn serverIdentity(
        self: *ReloadableIdentity,
    ) @TypeOf(self.current.identity.serverIdentity()) {
        return self.current.identity.serverIdentity();
    }

    /// The returned owner must outlive every provider lease.
    pub fn provider(self: *ReloadableIdentity) netz.tls.stream.ServerIdentityProvider {
        return .{
            .context = self,
            .acquire_fn = acquire,
        };
    }

    /// Swap in a new identity. The old generation is freed immediately when no
    /// handshake is using it, otherwise when the last lease is released.
    pub fn reload(self: *ReloadableIdentity, identity: Identity) !void {
        const generation = try self.allocator.create(Generation);
        generation.* = .{
            .owner = self,
            .identity = identity,
        };
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const previous = self.current;
        previous.owner = self;
        self.current = generation;
        previous.retired = true;
        if (previous.references == 0) self.destroyGeneration(previous);
    }

    /// Reload from PEM files relative to `dir`. Intended for SIGHUP handlers or
    /// a certificate watcher; ACME issuance remains an external concern.
    pub fn reloadFromFiles(
        self: *ReloadableIdentity,
        io: std.Io,
        dir: std.Io.Dir,
        certificate_path: []const u8,
        private_key_path: []const u8,
    ) !void {
        const identity = try netz.tls.server_identity_file.load(
            self.allocator,
            io,
            dir,
            certificate_path,
            private_key_path,
        );
        errdefer {
            var owned = identity;
            owned.deinit();
        }
        try self.reload(identity);
    }

    /// Release all generations. No handshake may be in flight.
    pub fn deinit(self: *ReloadableIdentity) void {
        self.mutex.lock(self.io) catch {
            self.destroyGeneration(self.current);
            self.* = undefined;
            return;
        };
        self.destroyGeneration(self.current);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    fn acquire(raw: *anyopaque) netz.tls.stream.ServerIdentityLease {
        const self: *ReloadableIdentity = @ptrCast(@alignCast(raw));
        self.mutex.lock(self.io) catch {};
        const generation = self.current;
        generation.owner = self;
        generation.references += 1;
        self.mutex.unlock(self.io);
        return .{
            .identity = generation.identity.serverIdentity(),
            .context = generation,
            .release_fn = release,
        };
    }

    fn release(raw: ?*anyopaque) void {
        const generation: *Generation = @ptrCast(@alignCast(raw orelse return));
        const self = generation.owner;
        self.mutex.lock(self.io) catch {
            generation.references -= 1;
            if (generation.retired and generation.references == 0) {
                self.destroyGeneration(generation);
            }
            return;
        };
        defer self.mutex.unlock(self.io);
        generation.references -= 1;
        if (generation.retired and generation.references == 0) {
            self.destroyGeneration(generation);
        }
    }

    fn destroyGeneration(self: *ReloadableIdentity, generation: *Generation) void {
        var identity = generation.identity;
        identity.deinit();
        self.allocator.destroy(generation);
    }
};

test "reloadable identity swaps generations and waits for leases" {
    const allocator = std.testing.allocator;
    const netz_tls = netz.tls;

    var certificate_der: [netz_tls.testing.certificate_der_len]u8 = undefined;
    try std.base64.standard.Decoder.decode(
        &certificate_der,
        netz_tls.testing.certificate_base64,
    );
    const key_pair = try netz_tls.testing.serverKeyPair();

    const chain = try allocator.alloc([]const u8, 1);
    chain[0] = try allocator.dupe(u8, &certificate_der);
    const first = Identity{
        .allocator = allocator,
        .certificate_chain = chain,
        .key_pair = .{ .ecdsa_p256_sha256 = key_pair },
    };
    var reloadable = try ReloadableIdentity.init(std.testing.io, allocator, first);
    defer reloadable.deinit();

    const provider = reloadable.provider();
    var lease = provider.acquire();
    try std.testing.expectEqual(@as(usize, 1), lease.identity.certificate_chain.len);
    lease.deinit();

    const chain2 = try allocator.alloc([]const u8, 1);
    chain2[0] = try allocator.dupe(u8, &certificate_der);
    try reloadable.reload(.{
        .allocator = allocator,
        .certificate_chain = chain2,
        .key_pair = .{ .ecdsa_p256_sha256 = key_pair },
    });

    var second_lease = provider.acquire();
    second_lease.deinit();
}
