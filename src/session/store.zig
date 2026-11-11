const std = @import("std");

pub const id_bytes = 32;
pub const id_hex_bytes = id_bytes * 2;
pub const SessionId = [id_bytes]u8;

pub const Options = struct {
    /// Maximum retained sessions. The oldest session is evicted on overflow.
    max_sessions: usize = 1024,
    /// Maximum key plus value bytes retained for one session.
    max_bytes_per_session: usize = 16 * 1024,
    /// Session expires after this long without a request.
    idle_timeout: std.Io.Duration = .fromSeconds(24 * 60 * 60),
    /// Session expires this long after creation regardless of activity.
    absolute_timeout: std.Io.Duration = .fromSeconds(7 * 24 * 60 * 60),
};

/// Bounded in-memory session storage.
///
/// The store is safe to share between handler workers. Values are copied in
/// and out under one mutex, so request code never holds a pointer into the
/// store while a handler runs.
pub const Store = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    sessions: std.AutoHashMapUnmanaged(SessionId, *Entry) = .empty,
    backend: ?Backend = null,
    /// Optional backend storage released by `deinit` (for `FileStore`).
    owned_backend: ?*anyopaque = null,
    owned_deinit_fn: ?*const fn (*anyopaque) void = null,
    options: Options,

    const Entry = struct {
        values: std.StringHashMapUnmanaged([]u8) = .empty,
        bytes: usize = 0,
        created_ns: i96,
        last_seen_ns: i96,
    };

    pub const Values = std.StringHashMapUnmanaged([]const u8);

    /// Pluggable storage for shared session deployments (Redis, SQL, or a
    /// shared filesystem). Callbacks must be thread-safe and copy values.
    pub const Backend = struct {
        context: *anyopaque,
        load_fn: *const fn (
            *anyopaque,
            std.Io,
            SessionId,
            std.mem.Allocator,
            i96,
        ) anyerror!?Values,
        save_fn: *const fn (
            *anyopaque,
            std.Io,
            SessionId,
            *const Values,
            i96,
        ) anyerror!bool,
        touch_fn: *const fn (*anyopaque, std.Io, SessionId, i96) bool,
        remove_fn: *const fn (*anyopaque, std.Io, SessionId) void,
        rotate_fn: *const fn (
            *anyopaque,
            std.Io,
            SessionId,
            SessionId,
            *const Values,
            i96,
        ) anyerror!void,
        count_fn: ?*const fn (*anyopaque) usize = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Store {
        try validateOptions(options);
        return .{ .allocator = allocator, .options = options };
    }

    pub fn initBackend(
        allocator: std.mem.Allocator,
        backend: Backend,
        options: Options,
    ) !Store {
        try validateOptions(options);
        return .{
            .allocator = allocator,
            .options = options,
            .backend = backend,
        };
    }

    pub fn deinit(self: *Store) void {
        if (self.owned_deinit_fn) |deinit_fn| {
            deinit_fn(self.owned_backend.?);
            self.* = undefined;
            return;
        }
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            self.freeEntry(entry.value_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
        self.* = undefined;
    }

    /// Copy one live session into `allocator`. Returns null when the id is
    /// unknown or expired.
    pub fn load(
        self: *Store,
        io: std.Io,
        id: SessionId,
        allocator: std.mem.Allocator,
        now_ns: i96,
    ) !?Values {
        if (self.backend) |backend| {
            return backend.load_fn(
                backend.context,
                io,
                id,
                allocator,
                now_ns,
            );
        }
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const entry = self.sessions.get(id) orelse return null;
        if (self.expired(entry, now_ns)) {
            _ = self.sessions.remove(id);
            self.freeEntry(entry);
            self.allocator.destroy(entry);
            return null;
        }

        var values: Values = .empty;
        errdefer {
            var iterator = values.iterator();
            while (iterator.next()) |item| {
                allocator.free(item.key_ptr.*);
                allocator.free(item.value_ptr.*);
            }
            values.deinit(allocator);
        }
        var iterator = entry.values.iterator();
        while (iterator.next()) |item| {
            const key = try allocator.dupe(u8, item.key_ptr.*);
            const value = try allocator.dupe(u8, item.value_ptr.*);
            try values.put(allocator, key, value);
        }
        entry.last_seen_ns = now_ns;
        return values;
    }

    /// Insert or replace one session. Values are copied from `values`.
    /// Returns true when a new entry was created.
    pub fn save(
        self: *Store,
        io: std.Io,
        id: SessionId,
        values: *const Values,
        now_ns: i96,
    ) !bool {
        if (self.backend) |backend| {
            return backend.save_fn(
                backend.context,
                io,
                id,
                values,
                now_ns,
            );
        }
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        return self.saveLocked(id, values, now_ns, true);
    }

    /// Refresh the idle deadline without copying values. Returns false when
    /// the session is no longer retained.
    pub fn touch(self: *Store, io: std.Io, id: SessionId, now_ns: i96) bool {
        if (self.backend) |backend| {
            return backend.touch_fn(backend.context, io, id, now_ns);
        }
        self.mutex.lock(io) catch return false;
        defer self.mutex.unlock(io);
        const entry = self.sessions.get(id) orelse return false;
        if (self.expired(entry, now_ns)) {
            _ = self.sessions.remove(id);
            self.freeEntry(entry);
            self.allocator.destroy(entry);
            return false;
        }
        entry.last_seen_ns = now_ns;
        return true;
    }

    /// Replace `old_id` with `new_id` atomically.
    pub fn rotate(
        self: *Store,
        io: std.Io,
        old_id: SessionId,
        new_id: SessionId,
        values: *const Values,
        now_ns: i96,
    ) !void {
        if (std.mem.eql(u8, &old_id, &new_id)) return error.SessionCollision;
        if (self.backend) |backend| {
            return backend.rotate_fn(
                backend.context,
                io,
                old_id,
                new_id,
                values,
                now_ns,
            );
        }
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        if (self.sessions.get(new_id) != null) return error.SessionCollision;
        if (self.sessions.get(old_id)) |old_entry| {
            _ = self.sessions.remove(old_id);
            self.freeEntry(old_entry);
            self.allocator.destroy(old_entry);
        }
        _ = try self.saveLocked(new_id, values, now_ns, true);
    }
    pub fn remove(self: *Store, io: std.Io, id: SessionId) void {
        if (self.backend) |backend| {
            return backend.remove_fn(backend.context, io, id);
        }
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        const entry = self.sessions.get(id) orelse return;
        _ = self.sessions.remove(id);
        self.freeEntry(entry);
        self.allocator.destroy(entry);
    }

    pub fn count(self: *Store, io: std.Io) usize {
        if (self.backend) |backend| {
            if (backend.count_fn) |count_fn| return count_fn(backend.context);
            return 0;
        }
        self.mutex.lock(io) catch return 0;
        defer self.mutex.unlock(io);
        return self.sessions.count();
    }

    pub fn randomId(io: std.Io) SessionId {
        var id: SessionId = undefined;
        io.random(&id);
        return id;
    }

    pub fn idToHex(id: SessionId) [id_hex_bytes]u8 {
        return std.fmt.bytesToHex(id, .lower);
    }

    pub fn idFromHex(raw: []const u8) ?SessionId {
        if (raw.len != id_hex_bytes) return null;
        var id: SessionId = undefined;
        _ = std.fmt.hexToBytes(&id, raw) catch return null;
        return id;
    }

    pub fn nowNanos(io: std.Io) i96 {
        return std.Io.Timestamp.now(io, .real).nanoseconds;
    }

    fn validateOptions(options: Options) !void {
        if (options.max_sessions == 0 or
            options.max_bytes_per_session == 0 or
            options.idle_timeout.nanoseconds <= 0 or
            options.absolute_timeout.nanoseconds <= 0)
        {
            return error.InvalidOptions;
        }
    }

    fn saveLocked(
        self: *Store,
        id: SessionId,
        values: *const Values,
        now_ns: i96,
        allow_create: bool,
    ) !bool {
        var bytes: usize = 0;
        var iterator = values.iterator();
        while (iterator.next()) |item| {
            bytes = std.math.add(usize, bytes, item.key_ptr.*.len) catch
                return error.SessionTooLarge;
            bytes = std.math.add(usize, bytes, item.value_ptr.*.len) catch
                return error.SessionTooLarge;
        }
        if (bytes > self.options.max_bytes_per_session) {
            return error.SessionTooLarge;
        }

        // Build the replacement before touching the live entry so allocation
        // failure leaves the previous session intact.
        var replacement: Entry = .{
            .bytes = bytes,
            .created_ns = now_ns,
            .last_seen_ns = now_ns,
        };
        errdefer self.freeEntry(&replacement);
        iterator = values.iterator();
        while (iterator.next()) |item| {
            const key = try self.allocator.dupe(u8, item.key_ptr.*);
            errdefer self.allocator.free(key);
            const value = try self.allocator.dupe(u8, item.value_ptr.*);
            errdefer self.allocator.free(value);
            try replacement.values.put(self.allocator, key, value);
        }

        if (self.sessions.get(id)) |entry| {
            replacement.created_ns = entry.created_ns;
            self.freeEntry(entry);
            entry.* = replacement;
            return false;
        }
        if (!allow_create) return error.SessionNotFound;

        while (self.sessions.count() >= self.options.max_sessions) {
            if (!self.evictOldest()) return error.SessionLimitReached;
        }
        const entry = try self.allocator.create(Entry);
        entry.* = replacement;
        // Ownership moved into the map entry; keep the error path from
        // freeing the same values twice.
        replacement = .{
            .created_ns = 0,
            .last_seen_ns = 0,
        };
        errdefer {
            self.freeEntry(entry);
            self.allocator.destroy(entry);
        }
        try self.sessions.put(self.allocator, id, entry);
        return true;
    }

    fn evictOldest(self: *Store) bool {
        var oldest_id: ?SessionId = null;
        var oldest_ns: i96 = std.math.maxInt(i96);
        var iterator = self.sessions.iterator();
        while (iterator.next()) |item| {
            if (item.value_ptr.*.last_seen_ns < oldest_ns) {
                oldest_ns = item.value_ptr.*.last_seen_ns;
                oldest_id = item.key_ptr.*;
            }
        }
        const id = oldest_id orelse return false;
        const entry = self.sessions.get(id) orelse return false;
        _ = self.sessions.remove(id);
        self.freeEntry(entry);
        self.allocator.destroy(entry);
        return true;
    }

    fn expired(self: *const Store, entry: *const Entry, now_ns: i96) bool {
        if (now_ns - entry.created_ns >= self.options.absolute_timeout.nanoseconds) {
            return true;
        }
        return now_ns - entry.last_seen_ns >= self.options.idle_timeout.nanoseconds;
    }

    fn freeEntry(self: *Store, entry: *Entry) void {
        var iterator = entry.values.iterator();
        while (iterator.next()) |item| {
            self.allocator.free(item.key_ptr.*);
            self.allocator.free(item.value_ptr.*);
        }
        entry.values.deinit(self.allocator);
        entry.* = .{
            .created_ns = 0,
            .last_seen_ns = 0,
        };
    }
};

fn freeValues(allocator: std.mem.Allocator, values: *Store.Values) void {
    var iterator = values.iterator();
    while (iterator.next()) |item| {
        allocator.free(item.key_ptr.*);
        allocator.free(item.value_ptr.*);
    }
    values.deinit(allocator);
}

test "session store copies values, expires, and evicts" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, .{
        .max_sessions = 2,
        .max_bytes_per_session = 64,
        .idle_timeout = .fromSeconds(10),
        .absolute_timeout = .fromSeconds(30_000),
    });
    defer store.deinit();

    const io = std.testing.io;
    var values: Store.Values = .empty;
    defer freeValues(allocator, &values);
    const key = try allocator.dupe(u8, "user");
    const value = try allocator.dupe(u8, "42");
    try values.put(allocator, key, value);

    const first = Store.randomId(io);
    _ = try store.save(io, first, &values, 1_000 * std.time.ns_per_ms);
    var loaded = (try store.load(io, first, allocator, 1_500 * std.time.ns_per_ms)).?;
    defer freeValues(allocator, &loaded);
    try std.testing.expectEqualStrings("42", loaded.get("user").?);

    // Idle expiry.
    try std.testing.expect((try store.load(io, first, allocator, 12_000 * std.time.ns_per_ms)) == null);

    // Capacity eviction keeps the newest session.
    _ = try store.save(io, first, &values, 20_000 * std.time.ns_per_ms);
    const second = Store.randomId(io);
    _ = try store.save(io, second, &values, 20_001 * std.time.ns_per_ms);
    const third = Store.randomId(io);
    _ = try store.save(io, third, &values, 20_002 * std.time.ns_per_ms);
    try std.testing.expect((try store.load(io, first, allocator, 20_003 * std.time.ns_per_ms)) == null);
    var second_loaded = (try store.load(io, second, allocator, 20_003 * std.time.ns_per_ms)).?;
    defer freeValues(allocator, &second_loaded);
    var third_loaded = (try store.load(io, third, allocator, 20_003 * std.time.ns_per_ms)).?;
    defer freeValues(allocator, &third_loaded);
    try std.testing.expectEqualStrings("42", second_loaded.get("user").?);
    try std.testing.expectEqualStrings("42", third_loaded.get("user").?);
}
