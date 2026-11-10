//! Measures the producer cost of weft's structured access-log shape through
//! kron. Run with `zig build bench-logging -Doptimize=ReleaseFast`.
const std = @import("std");
const kron = @import("kron");
const netz = @import("netz");

const iterations: usize = 200_000;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var discard_buffer: [4096]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&discard_buffer);
    const logging = try kron.Logging.create(allocator, io, .{
        .outputs = &.{.{
            .name = "discard",
            .target = .{ .writer = &discard.writer },
            .mode = .sync,
            .format = .json,
            .filter = "info",
        }},
    });
    defer logging.destroy();
    const log = logging.scoped("weft.http");

    var index: usize = 0;
    while (index < 1000) : (index += 1) try emitOne(log);

    var started = std.Io.Timestamp.now(io, .awake);
    index = 0;
    while (index < iterations) : (index += 1) try emitOne(log);
    var elapsed = started.untilNow(io, .awake);
    printResult("kron sync json 9 fields", elapsed);

    // The direct per-output runtime logger skips the multi-output facade.
    const direct = try logging.scopedOutput("discard", "weft.http");
    index = 0;
    while (index < 1000) : (index += 1) try emitOne(direct);
    started = std.Io.Timestamp.now(io, .awake);
    index = 0;
    while (index < iterations) : (index += 1) try emitOne(direct);
    elapsed = started.untilNow(io, .awake);
    printResult("kron sync json 9 fields (direct)", elapsed);

    var async_discard_buffer: [4096]u8 = undefined;
    var async_discard = std.Io.Writer.Discarding.init(&async_discard_buffer);
    const async_logging = try kron.Logging.create(allocator, io, .{
        .outputs = &.{.{
            .name = "discard",
            .target = .{ .writer = &async_discard.writer },
            .mode = .asynchronous,
            .format = .json,
            .filter = "info",
        }},
    });
    defer async_logging.destroy();
    const async_log = async_logging.scoped("weft.http");

    index = 0;
    while (index < 1000) : (index += 1) try emitOne(async_log);
    started = std.Io.Timestamp.now(io, .awake);
    index = 0;
    while (index < iterations) : (index += 1) try emitOne(async_log);
    elapsed = started.untilNow(io, .awake);
    printResult("kron async json 9 fields", elapsed);
    try async_logging.flush();
    try async_logging.shutdown();
}

fn emitOne(log: anytype) !void {
    _ = try log.tryEmit(.info, "request completed", .{
        .request_id = "4811a155e5392b3296f10705127cf9fb",
        .method = "GET",
        .path = "/hello/alice",
        .query = "x=1",
        .status = @as(u16, 200),
        .duration_ns = @as(u64, 54830),
        .protocol = "http_1_1",
        .remote = "127.0.0.1:47950",
        .err = "",
    });
}

fn printResult(label: []const u8, elapsed: std.Io.Duration) void {
    const ns: f64 = @floatFromInt(@max(elapsed.nanoseconds, 0));
    std.debug.print(
        "{s}: {d:.1} ns/event ({d:.0} events/s)\n",
        .{
            label,
            ns / @as(f64, @floatFromInt(iterations)),
            @as(f64, @floatFromInt(iterations)) /
                (ns / std.time.ns_per_s),
        },
    );
}
