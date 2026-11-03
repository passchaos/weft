const std = @import("std");
const weft = @import("weft");

fn noop(ctx: *weft.Ctx) anyerror!void {
    _ = ctx;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try benchStatic(allocator, io, 1024, 2_000_000);
    try benchParam(allocator, io, 256, 1_000_000);
}

fn benchStatic(
    allocator: std.mem.Allocator,
    io: std.Io,
    route_count: usize,
    iterations: usize,
) !void {
    var router = weft.Router(void).init(allocator);
    defer router.deinit();

    const paths = try allocator.alloc([]u8, route_count);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    for (paths, 0..) |*path, index| {
        path.* = try std.fmt.allocPrint(
            allocator,
            "/api/v1/resource{d}",
            .{index},
        );
        try router.addRaw(.GET, path.*, weft.handler(noop), .{});
    }

    for (paths) |path| {
        const matched = try router.resolve(.GET, path, allocator);
        if (matched != .matched) return error.BenchmarkMismatch;
    }

    var checksum: usize = 0;
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..iterations) |iteration| {
        const index = (iteration * 7919) % route_count;
        const matched = try router.resolve(.GET, paths[index], allocator);
        switch (matched) {
            .matched => |match| checksum += match.route.pattern.len,
            else => unreachable,
        }
    }
    const elapsed = start.untilNow(io, .awake);
    std.mem.doNotOptimizeAway(checksum);

    printResult("static", route_count, iterations, elapsed.nanoseconds);
}

fn benchParam(
    allocator: std.mem.Allocator,
    io: std.Io,
    route_count: usize,
    iterations: usize,
) !void {
    var router = weft.Router(void).init(allocator);
    defer router.deinit();

    const patterns = try allocator.alloc([]u8, route_count);
    defer {
        for (patterns) |pattern| allocator.free(pattern);
        allocator.free(patterns);
    }
    const paths = try allocator.alloc([]u8, route_count);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    for (patterns, paths, 0..) |*pattern, *path, index| {
        pattern.* = try std.fmt.allocPrint(
            allocator,
            "/api/v1/item{d}/:id",
            .{index},
        );
        path.* = try std.fmt.allocPrint(
            allocator,
            "/api/v1/item{d}/42",
            .{index},
        );
        try router.addRaw(.GET, pattern.*, weft.handler(noop), .{});
    }

    var arena_buffer: [64 * 1024]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&arena_buffer);

    for (paths) |path| {
        arena.reset();
        const matched = try router.resolve(.GET, path, arena.allocator());
        if (matched != .matched) return error.BenchmarkMismatch;
    }

    var checksum: usize = 0;
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..iterations) |iteration| {
        arena.reset();
        const index = (iteration * 7919) % route_count;
        const matched = try router.resolve(
            .GET,
            paths[index],
            arena.allocator(),
        );
        switch (matched) {
            .matched => |match| checksum += match.params[0].value.len,
            else => unreachable,
        }
    }
    const elapsed = start.untilNow(io, .awake);
    std.mem.doNotOptimizeAway(checksum);

    printResult("param", route_count, iterations, elapsed.nanoseconds);
}

fn printResult(
    kind: []const u8,
    route_count: usize,
    iterations: usize,
    nanoseconds: i96,
) void {
    const elapsed_ns = @as(f64, @floatFromInt(nanoseconds));
    const count = @as(f64, @floatFromInt(iterations));
    const ns_per_lookup = elapsed_ns / count;
    const lookups_per_second = count / (elapsed_ns / std.time.ns_per_s);
    std.debug.print(
        "router {s}: routes={d} lookups={d} {d:.1} ns/lookup {d:.0} lookups/s\n",
        .{ kind, route_count, iterations, ns_per_lookup, lookups_per_second },
    );
}
