const std = @import("std");

/// Default bytes copied into one slot. Transport chunks larger than this are
/// split so a single slot never exceeds the window budget.
pub const default_slot_bytes = 16 * 1024;

/// Hard cap on the number of slots, independent of the configured window.
pub const max_slots = 64;

const Chunk = struct {
    index: usize,
    len: usize,
};

/// Bounded producer/consumer bridge between a protocol body reader and an
/// application handler running in a separate task.
///
/// The producer (`push`/`finish`) copies chunks into a fixed ring of slots.
/// The consumer (`next`/`drain`) reads them and returns each slot to the free
/// list. When the handler stops reading early, `drain` discards the remainder
/// so the protocol reader can finish the body and keep the connection alive.
pub const Reader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    buffer: []u8,
    slot_bytes: usize,
    slots: usize,
    filled_storage: []Chunk,
    free_storage: []usize,
    filled: std.Io.Queue(Chunk),
    free: std.Io.Queue(usize),
    current: ?Chunk = null,
    finished: bool = false,
    owned: bool = true,
    /// Slice-backed replay used by adapters that already buffered the body.
    replay: ?[]const u8 = null,
    replay_consumed: bool = false,

    /// Allocate a window of at most `window_bytes` bytes. A window smaller than
    /// one slot becomes a single slot of that size.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        window_bytes: usize,
    ) !Reader {
        if (window_bytes == 0) return error.InvalidWindow;

        const slot_bytes: usize = @min(default_slot_bytes, window_bytes);
        const slots: usize = @max(
            1,
            @min(max_slots, window_bytes / slot_bytes),
        );
        const total_bytes = std.math.mul(
            usize,
            slot_bytes,
            slots,
        ) catch return error.InvalidWindow;

        const buffer = try allocator.alloc(u8, total_bytes);
        errdefer allocator.free(buffer);
        const filled_storage = try allocator.alloc(Chunk, slots);
        errdefer allocator.free(filled_storage);
        const free_storage = try allocator.alloc(usize, slots);
        errdefer allocator.free(free_storage);

        var reader = Reader{
            .allocator = allocator,
            .io = io,
            .buffer = buffer,
            .slot_bytes = slot_bytes,
            .slots = slots,
            .filled_storage = filled_storage,
            .free_storage = free_storage,
            .filled = std.Io.Queue(Chunk).init(filled_storage),
            .free = std.Io.Queue(usize).init(free_storage),
        };

        var initial: [max_slots]usize = undefined;
        for (initial[0..slots], 0..) |*slot, index| slot.* = index;
        try reader.free.putAll(io, initial[0..slots]);
        return reader;
    }

    /// Wrap an already-buffered body as a one-chunk reader. No allocation or
    /// synchronization is performed; adapters that cannot deliver DATA
    /// incrementally use this to keep `Ctx.bodyReader()` usable.
    pub fn initReplay(body: []const u8) Reader {
        return .{
            .allocator = undefined,
            .io = undefined,
            .buffer = &.{},
            .slot_bytes = 0,
            .slots = 0,
            .filled_storage = &.{},
            .free_storage = &.{},
            .filled = undefined,
            .free = undefined,
            .owned = false,
            .replay = body,
        };
    }

    pub fn deinit(self: *Reader) void {
        if (!self.owned) {
            self.* = undefined;
            return;
        }
        self.allocator.free(self.buffer);
        self.allocator.free(self.filled_storage);
        self.allocator.free(self.free_storage);
        self.* = undefined;
    }

    /// Copy one protocol chunk into the window. Splits chunks larger than a
    /// slot and blocks while all slots are in use.
    pub fn push(self: *Reader, data: []const u8) !void {
        if (self.finished) return error.StreamFinished;

        var remaining = data;
        while (remaining.len > 0) {
            const length = @min(remaining.len, self.slot_bytes);
            const index = self.free.getOne(self.io) catch |err| switch (err) {
                error.Closed => return error.StreamFinished,
                else => return err,
            };
            const start = index * self.slot_bytes;
            @memcpy(self.buffer[start .. start + length], remaining[0..length]);
            self.filled.putOne(self.io, .{
                .index = index,
                .len = length,
            }) catch |err| {
                self.free.putOne(self.io, index) catch {};
                return err;
            };
            remaining = remaining[length..];
        }
    }

    /// Signal that no further chunks will be pushed.
    pub fn finish(self: *Reader) void {
        if (self.finished) return;
        self.finished = true;
        self.filled.close(self.io);
    }

    /// Return the next chunk, or null once the producer has finished and all
    /// chunks have been consumed. The slice stays valid until the next call to
    /// `next`, `drain`, or `deinit`.
    pub fn next(self: *Reader) !?[]const u8 {
        if (self.replay) |body| {
            if (self.replay_consumed) return null;
            self.replay_consumed = true;
            return body;
        }
        self.releaseCurrent();
        const chunk = self.filled.getOne(self.io) catch |err| switch (err) {
            error.Closed => return null,
            else => return err,
        };
        self.current = chunk;
        const start = chunk.index * self.slot_bytes;
        return self.buffer[start .. start + chunk.len];
    }

    /// Discard remaining chunks until the producer finishes. Used after the
    /// handler returns so the connection can finish reading the body.
    pub fn drain(self: *Reader) void {
        while (self.next() catch null) |_| {}
        self.releaseCurrent();
    }

    fn releaseCurrent(self: *Reader) void {
        const chunk = self.current orelse return;
        self.current = null;
        self.free.putOne(self.io, chunk.index) catch {};
    }
};

test "body stream replay yields one chunk without allocation" {
    var reader = Reader.initReplay("hello");
    defer reader.deinit();
    try std.testing.expectEqualStrings("hello", (try reader.next()).?);
    try std.testing.expect((try reader.next()) == null);
}

test "body stream splits chunks and preserves order" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reader = try Reader.init(allocator, io, 32 * 1024);
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 2), reader.slots);
    try std.testing.expectEqual(@as(usize, 16 * 1024), reader.slot_bytes);

    const payload = try allocator.alloc(u8, 40 * 1024);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @intCast(index % 251);

    // Two slots fit immediately; the third push blocks until the consumer
    // drains, so run the producer concurrently.
    const Producer = struct {
        reader: *Reader,
        payload: []const u8,
        fn run(self: @This()) !void {
            try self.reader.push(self.payload);
            self.reader.finish();
        }
    };
    var future = try std.Io.concurrent(io, Producer.run, .{Producer{
        .reader = &reader,
        .payload = payload,
    }});

    var received = std.ArrayListUnmanaged(u8).empty;
    defer received.deinit(allocator);
    while (try reader.next()) |chunk| {
        try received.appendSlice(allocator, chunk);
    }
    try future.await(io);

    try std.testing.expectEqualSlices(u8, payload, received.items);
}

test "body stream drain releases slots for early handler exits" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reader = try Reader.init(allocator, io, 16 * 1024);
    defer reader.deinit();

    const Producer = struct {
        reader: *Reader,
        fn run(self: @This()) !void {
            var index: usize = 0;
            while (index < 8) : (index += 1) {
                try self.reader.push("chunk");
            }
            self.reader.finish();
        }
    };
    var future = try std.Io.concurrent(io, Producer.run, .{Producer{
        .reader = &reader,
    }});

    // Read one chunk, then stop; drain must consume the rest so the producer
    // can complete.
    const first = (try reader.next()).?;
    try std.testing.expectEqualStrings("chunk", first);
    reader.drain();
    try future.await(io);
}
