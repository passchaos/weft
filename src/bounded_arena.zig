//! A per-request arena bounded by `Limits.max_request_arena_bytes`.
//!
//! Unlike a `FixedBufferAllocator` over an eagerly allocated 64 KiB buffer,
//! this arena allocates backing chunks only when the handler actually uses
//! them. Requests whose handlers never touch `ctx.arena` pay no heap
//! allocation at all, and small handlers allocate a small chunk instead of the
//! full configured bound.
//!
//! A small inline first chunk covers the common request (a response body and
//! a few copied header fields), so typical requests never reach the child
//! allocator at all.
const std = @import("std");

pub const BoundedArena = struct {
    /// Bytes served from the arena struct itself before any backing chunk is
    /// requested. Sized for a small response body plus a handful of headers.
    pub const inline_capacity: usize = 256;

    arena: std.heap.ArenaAllocator,
    limit: usize,
    used: usize = 0,
    /// Inline first chunk. Allocations are bump-allocated here while they fit;
    /// the child allocator is only touched after it is exhausted.
    inline_storage: [inline_capacity]u8 align(16) = undefined,
    inline_used: usize = 0,

    pub fn init(child_allocator: std.mem.Allocator, limit: usize) BoundedArena {
        return .{ .arena = .init(child_allocator), .limit = limit };
    }

    pub fn deinit(self: *BoundedArena) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *BoundedArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Whether `pointer` lies in the inline first chunk.
    inline fn isInline(self: *const BoundedArena, pointer: usize) bool {
        const base = @intFromPtr(&self.inline_storage);
        return pointer >= base and pointer < base + self.inline_storage.len;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *BoundedArena = @ptrCast(@alignCast(context));
        const next = std.math.add(usize, self.used, len) catch return null;
        if (next > self.limit) return null;

        // Align by absolute address, not by offset: the struct's own alignment
        // only guarantees 16 bytes, and a request may ask for more.
        const base = @intFromPtr(&self.inline_storage);
        const start = std.mem.alignForward(
            usize,
            base + self.inline_used,
            alignment.toByteUnits(),
        );
        const offset = start - base;
        if (offset + len <= self.inline_storage.len) {
            self.inline_used = offset + len;
            self.used = next;
            return @ptrFromInt(start);
        }

        const result = self.arena.allocator().rawAlloc(
            len,
            alignment,
            ret_addr,
        ) orelse return null;
        self.used = next;
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *BoundedArena = @ptrCast(@alignCast(context));
        if (self.isInline(@intFromPtr(memory.ptr))) {
            // Only the newest inline allocation can change size in place; the
            // arena never reclaims older bytes, so growing them would overlap.
            const base = @intFromPtr(&self.inline_storage);
            const offset = @intFromPtr(memory.ptr) - base;
            if (offset + memory.len != self.inline_used) return false;
            const new_end = offset + new_len;
            if (new_end > self.inline_storage.len) return false;
            if (new_len >= memory.len) {
                const next = std.math.add(
                    usize,
                    self.used,
                    new_len - memory.len,
                ) catch return false;
                if (next > self.limit) return false;
                self.used = next;
            } else {
                self.used -= memory.len - new_len;
            }
            self.inline_used = new_end;
            return true;
        }
        if (new_len > memory.len) {
            const next = std.math.add(
                usize,
                self.used,
                new_len - memory.len,
            ) catch return false;
            if (next > self.limit) return false;
        }
        if (!self.arena.allocator().rawResize(
            memory,
            alignment,
            new_len,
            ret_addr,
        )) return false;
        if (new_len >= memory.len) {
            self.used += new_len - memory.len;
        } else {
            self.used -|= memory.len - new_len;
        }
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *BoundedArena = @ptrCast(@alignCast(context));
        // Inline memory cannot move; the caller falls back to alloc + copy.
        if (self.isInline(@intFromPtr(memory.ptr))) return null;
        if (new_len > memory.len) {
            const next = std.math.add(
                usize,
                self.used,
                new_len - memory.len,
            ) catch return null;
            if (next > self.limit) return null;
        }
        const result = self.arena.allocator().rawRemap(
            memory,
            alignment,
            new_len,
            ret_addr,
        ) orelse return null;
        if (new_len >= memory.len) {
            self.used += new_len - memory.len;
        } else {
            self.used -|= memory.len - new_len;
        }
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *BoundedArena = @ptrCast(@alignCast(context));
        if (self.isInline(@intFromPtr(memory.ptr))) return;
        self.arena.allocator().rawFree(memory, alignment, ret_addr);
    }
};

test "bounded arena enforces the request budget and frees chunks" {
    var arena = BoundedArena.init(std.testing.allocator, 256);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try allocator.alloc(u8, 100);
    const second = try allocator.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 200), arena.used);
    try std.testing.expectError(
        error.OutOfMemory,
        allocator.alloc(u8, 100),
    );
    try std.testing.expectEqual(@as(usize, 200), arena.used);
    try std.testing.expect(first.ptr != second.ptr);

    // Frees are arena no-ops: the budget counts allocated bytes, not live
    // bytes, so a freed allocation cannot be reused to exceed the bound.
    allocator.free(first);
    try std.testing.expectError(
        error.OutOfMemory,
        allocator.alloc(u8, 100),
    );
}

test "bounded arena serves small requests from the inline chunk" {
    var tiny: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&tiny);
    var arena = BoundedArena.init(fixed.allocator(), 1024);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Init must not touch the backing store.
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);

    // Small allocations are bump-allocated inside the arena struct, so the
    // one-byte backing store is never used.
    const small = try allocator.alloc(u8, 2);
    try std.testing.expect(arena.isInline(@intFromPtr(small.ptr)));
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);

    // Exhausting the inline chunk falls back to the child allocator, which
    // here can only fail.
    try std.testing.expectError(
        error.OutOfMemory,
        allocator.alloc(u8, BoundedArena.inline_capacity),
    );
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "bounded arena inline resize only moves the newest allocation" {
    var arena = BoundedArena.init(std.testing.allocator, 1024);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try allocator.alloc(u8, 16);
    const second = try allocator.alloc(u8, 16);
    try std.testing.expect(arena.isInline(@intFromPtr(first.ptr)));
    try std.testing.expect(arena.isInline(@intFromPtr(second.ptr)));

    // The older allocation cannot grow in place; the newest one can.
    try std.testing.expect(!allocator.resize(first, 32));
    try std.testing.expect(allocator.resize(second, 32));
    try std.testing.expectEqual(@as(usize, 48), arena.used);
    const grown: []u8 = second.ptr[0..32];
    try std.testing.expect(allocator.resize(grown, 8));
    try std.testing.expectEqual(@as(usize, 24), arena.used);
}

test "bounded arena falls back to chunks beyond the inline buffer" {
    var arena = BoundedArena.init(std.testing.allocator, 4096);
    defer arena.deinit();
    const allocator = arena.allocator();

    const large = try allocator.alloc(u8, BoundedArena.inline_capacity + 64);
    try std.testing.expect(!arena.isInline(@intFromPtr(large.ptr)));
    try std.testing.expectEqual(
        @as(usize, BoundedArena.inline_capacity + 64),
        arena.used,
    );
    // A later small allocation still fits the remaining inline space.
    const small = try allocator.alloc(u8, 8);
    try std.testing.expect(arena.isInline(@intFromPtr(small.ptr)));
}
