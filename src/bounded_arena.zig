//! A per-request arena bounded by `Limits.max_request_arena_bytes`.
//!
//! Unlike a `FixedBufferAllocator` over an eagerly allocated 64 KiB buffer,
//! this arena allocates backing chunks only when the handler actually uses
//! them. Requests whose handlers never touch `ctx.arena` pay no heap
//! allocation at all, and small handlers allocate a small chunk instead of the
//! full configured bound.
const std = @import("std");

pub const BoundedArena = struct {
    arena: std.heap.ArenaAllocator,
    limit: usize,
    used: usize = 0,

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
