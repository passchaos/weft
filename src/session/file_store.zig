const std = @import("std");
const store_mod = @import("store.zig");

const Store = store_mod.Store;
const SessionId = store_mod.SessionId;
const Values = Store.Values;

const magic = "WFS1";
const header_bytes = magic.len + 8 + 8 + 4;

/// File-backed session storage for shared-filesystem deployments.
///
/// Each session is one file written with `Dir.createFileAtomic`, so readers
/// never observe a partial update. Multiple processes sharing the directory
/// see the same sessions; concurrent writers are last-writer-wins. The store
/// does not evict across processes, so `max_sessions` is enforced by the
/// deployment (or by an external cleaner).
pub const FileStore = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        options: store_mod.Options,
    ) !Store {
        _ = try Store.init(allocator, options);
        const backend = try allocator.create(Backend);
        errdefer allocator.destroy(backend);
        backend.* = .{
            .allocator = allocator,
            .dir = dir,
            .options = options,
        };
        var store = try Store.initBackend(allocator, backend.interface(), options);
        store.owned_backend = backend;
        store.owned_deinit_fn = deinitBackend;
        return store;
    }
};

const Backend = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    options: store_mod.Options,

    fn interface(self: *Backend) Store.Backend {
        return .{
            .context = self,
            .load_fn = load,
            .save_fn = save,
            .touch_fn = touch,
            .remove_fn = remove,
            .rotate_fn = rotate,
        };
    }

    fn load(
        raw: *anyopaque,
        io: std.Io,
        id: SessionId,
        allocator: std.mem.Allocator,
        now_ns: i96,
    ) anyerror!?Values {
        const self: *Backend = @ptrCast(@alignCast(raw));
        var path_buffer: [80]u8 = undefined;
        const path = pathFor(&path_buffer, id);
        const bytes = self.dir.readFileAlloc(
            io,
            path,
            allocator,
            .limited(self.options.max_bytes_per_session + header_bytes + 64),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(bytes);

        const parsed = try parseHeader(bytes);
        if (self.expired(parsed.created_ns, parsed.last_seen_ns, now_ns)) {
            self.dir.deleteFile(io, path) catch {};
            return null;
        }
        return try parseValues(allocator, bytes, parsed.count);
    }

    fn save(
        raw: *anyopaque,
        io: std.Io,
        id: SessionId,
        values: *const Values,
        now_ns: i96,
    ) anyerror!bool {
        const self: *Backend = @ptrCast(@alignCast(raw));
        var bytes_count: usize = 0;
        var iterator = values.iterator();
        while (iterator.next()) |item| {
            bytes_count = std.math.add(
                usize,
                bytes_count,
                item.key_ptr.*.len + item.value_ptr.*.len + 8,
            ) catch return error.SessionTooLarge;
        }
        if (bytes_count > self.options.max_bytes_per_session) {
            return error.SessionTooLarge;
        }

        var path_buffer: [80]u8 = undefined;
        const path = pathFor(&path_buffer, id);
        var created_ns = now_ns;
        var created_from_file = false;
        if (self.dir.readFileAlloc(
            io,
            path,
            self.allocator,
            .limited(header_bytes),
        )) |existing| {
            defer self.allocator.free(existing);
            if (parseHeader(existing)) |parsed| {
                created_ns = parsed.created_ns;
                created_from_file = true;
            } else |_| {}
        } else |_| {}

        const encoded = try encode(
            self.allocator,
            values,
            created_ns,
            now_ns,
        );
        defer self.allocator.free(encoded);
        var atomic = try self.dir.createFileAtomic(io, path, .{
            .replace = true,
            .make_path = true,
        });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, encoded);
        try atomic.file.sync(io);
        try atomic.replace(io);
        return !created_from_file;
    }

    fn touch(
        raw: *anyopaque,
        io: std.Io,
        id: SessionId,
        now_ns: i96,
    ) bool {
        const self: *Backend = @ptrCast(@alignCast(raw));
        var values = (load(
            raw,
            io,
            id,
            self.allocator,
            now_ns,
        ) catch return false) orelse return false;
        defer freeValues(self.allocator, &values);
        _ = save(raw, io, id, &values, now_ns) catch return false;
        return true;
    }

    fn remove(raw: *anyopaque, io: std.Io, id: SessionId) void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        var path_buffer: [80]u8 = undefined;
        const path = pathFor(&path_buffer, id);
        self.dir.deleteFile(io, path) catch {};
    }

    fn rotate(
        raw: *anyopaque,
        io: std.Io,
        old_id: SessionId,
        new_id: SessionId,
        values: *const Values,
        now_ns: i96,
    ) anyerror!void {
        _ = try save(raw, io, new_id, values, now_ns);
        remove(raw, io, old_id);
    }

    fn expired(
        self: *Backend,
        created_ns: i96,
        last_seen_ns: i96,
        now_ns: i96,
    ) bool {
        if (now_ns - created_ns >= self.options.absolute_timeout.nanoseconds) {
            return true;
        }
        return now_ns - last_seen_ns >= self.options.idle_timeout.nanoseconds;
    }
};

fn deinitBackend(raw: *anyopaque) void {
    const self: *Backend = @ptrCast(@alignCast(raw));
    self.allocator.destroy(self);
}

fn pathFor(buffer: *[80]u8, id: SessionId) []const u8 {
    const hex = Store.idToHex(id);
    return std.fmt.bufPrint(buffer, "session-{s}.bin", .{&hex}) catch
        unreachable;
}

const Header = struct {
    created_ns: i96,
    last_seen_ns: i96,
    count: u32,
};

fn parseHeader(bytes: []const u8) !Header {
    if (bytes.len < header_bytes) return error.InvalidSessionFile;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) {
        return error.InvalidSessionFile;
    }
    var index: usize = magic.len;
    const created = try readInt(i64, bytes, &index);
    const last_seen = try readInt(i64, bytes, &index);
    const count = try readInt(u32, bytes, &index);
    return .{
        .created_ns = created,
        .last_seen_ns = last_seen,
        .count = count,
    };
}

fn parseValues(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    count: u32,
) !Values {
    var index: usize = header_bytes;
    var values: Values = .empty;
    errdefer freeValues(allocator, &values);
    var item_index: u32 = 0;
    while (item_index < count) : (item_index += 1) {
        const key_len = try readInt(u32, bytes, &index);
        const value_len = try readInt(u32, bytes, &index);
        if (key_len == 0 or
            index + key_len + value_len > bytes.len)
        {
            return error.InvalidSessionFile;
        }
        const key = try allocator.dupe(u8, bytes[index..][0..key_len]);
        errdefer allocator.free(key);
        index += key_len;
        const value = try allocator.dupe(u8, bytes[index..][0..value_len]);
        errdefer allocator.free(value);
        index += value_len;
        try values.put(allocator, key, value);
    }
    if (index != bytes.len) return error.InvalidSessionFile;
    return values;
}

fn encode(
    allocator: std.mem.Allocator,
    values: *const Values,
    created_ns: i96,
    last_seen_ns: i96,
) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(magic);
    try writer.writer.writeInt(i64, clampI64(created_ns), .little);
    try writer.writer.writeInt(i64, clampI64(last_seen_ns), .little);
    try writer.writer.writeInt(u32, @intCast(values.count()), .little);
    var iterator = values.iterator();
    while (iterator.next()) |item| {
        try writer.writer.writeInt(u32, @intCast(item.key_ptr.*.len), .little);
        try writer.writer.writeInt(
            u32,
            @intCast(item.value_ptr.*.len),
            .little,
        );
        try writer.writer.writeAll(item.key_ptr.*);
        try writer.writer.writeAll(item.value_ptr.*);
    }
    return writer.toOwnedSlice();
}

fn clampI64(value: i96) i64 {
    if (value > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (value < std.math.minInt(i64)) return std.math.minInt(i64);
    return @intCast(value);
}

fn readInt(
    comptime T: type,
    bytes: []const u8,
    index: *usize,
) !T {
    const size = @sizeOf(T);
    if (index.* + size > bytes.len) return error.InvalidSessionFile;
    const value = std.mem.readInt(
        T,
        bytes[index.*..][0..size],
        .little,
    );
    index.* += size;
    return value;
}

fn freeValues(allocator: std.mem.Allocator, values: *Values) void {
    var iterator = values.iterator();
    while (iterator.next()) |item| {
        allocator.free(item.key_ptr.*);
        allocator.free(item.value_ptr.*);
    }
    values.deinit(allocator);
}

test "file store shares sessions across instances and rotates ids" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try FileStore.init(allocator, tmp.dir, .{
        .max_sessions = 8,
        .idle_timeout = .fromSeconds(60),
        .absolute_timeout = .fromSeconds(600),
    });
    defer first.deinit();
    const io = std.testing.io;
    const now = 1_000 * std.time.ns_per_ms;

    var values: Values = .empty;
    defer freeValues(allocator, &values);
    try values.put(
        allocator,
        try allocator.dupe(u8, "user"),
        try allocator.dupe(u8, "42"),
    );
    const id = Store.randomId(io);
    _ = try first.save(io, id, &values, now);

    var second = try FileStore.init(allocator, tmp.dir, .{
        .max_sessions = 8,
        .idle_timeout = .fromSeconds(60),
        .absolute_timeout = .fromSeconds(600),
    });
    defer second.deinit();

    var loaded = (try second.load(io, id, allocator, now + 1_000)).?;
    defer freeValues(allocator, &loaded);
    try std.testing.expectEqualStrings("42", loaded.get("user").?);

    const rotated = Store.randomId(io);
    try second.rotate(io, id, rotated, &values, now + 2_000);
    try std.testing.expect((try first.load(io, id, allocator, now + 3_000)) == null);
    var rotated_loaded = (try first.load(
        io,
        rotated,
        allocator,
        now + 3_000,
    )).?;
    defer freeValues(allocator, &rotated_loaded);
    try std.testing.expectEqualStrings("42", rotated_loaded.get("user").?);

    first.remove(io, rotated);
    try std.testing.expect((try second.load(io, rotated, allocator, now + 4_000)) == null);
}
