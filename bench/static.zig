//! Static-file handler benchmark.
//!
//! Measures the `StaticFiles` handler end to end in-process: path
//! normalization, stat, validators, and streamed file reads, with a fixed
//! request arena. Socket work is excluded so the numbers isolate weft's static
//! serving cost.

const std = @import("std");
const netz = @import("netz");
const weft = @import("weft");

const large_iterations: usize = 20_000;
const small_iterations: usize = 100_000;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = try std.fmt.allocPrint(
        allocator,
        "/tmp/weft-static-bench-{d}",
        .{std.os.linux.getpid()},
    );
    defer allocator.free(root);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer cwd.deleteTree(io, root) catch {};

    const large = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(large);
    for (large, 0..) |*byte, index| byte.* = @truncate(index);
    const small = try allocator.alloc(u8, 1024);
    defer allocator.free(small);
    @memset(small, 's');

    var dir = try cwd.openDir(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "large.bin", .data = large });
    try dir.writeFile(io, .{ .sub_path = "small.txt", .data = small });

    var files = weft.StaticFiles{
        .dir = dir,
        .precompressed = false,
    };
    const handler = files.handler();

    try bench(allocator, io, handler, "large.bin", large_iterations, large.len);
    try bench(allocator, io, handler, "small.txt", small_iterations, small.len);
}

fn bench(
    allocator: std.mem.Allocator,
    io: std.Io,
    handler: weft.Handler,
    name: []const u8,
    iterations: usize,
    expected_bytes: usize,
) !void {
    const arena_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(arena_buffer);

    var target_buffer: [128]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "/assets/{s}", .{name});
    const params = [_]weft.Param{.{ .name = "*", .value = name }};
    var headers: [0]netz.http1.Header = .{};

    var sink = Sink{};
    var writer = weft.StreamWriter{
        .context = &sink,
        .write_fn = Sink.write,
    };

    var total: usize = 0;
    var index: usize = 0;
    const start = std.Io.Timestamp.now(io, .awake);
    while (index < iterations) : (index += 1) {
        var fixed = std.heap.FixedBufferAllocator.init(arena_buffer);
        const arena = fixed.allocator();
        var request = netz.http1.Request{
            .method = .GET,
            .target = target,
            .version = .http_1_1,
            .headers = &headers,
            .body = "",
            .consumed = 0,
        };
        var ctx = weft.Ctx{
            .app = undefined,
            .io = io,
            .arena = arena,
            .limits = .{ .max_response_bytes = 1024 * 1024 },
            .request = &request,
            .params = &params,
            .response = weft.Response.init(arena, 1024 * 1024),
            .final_handler = handler,
        };
        try ctx.run();
        if (ctx.response.status != 200) return error.BenchmarkStatus;
        if (ctx.response.stream) |body| {
            sink.bytes = 0;
            try body.run(&writer);
            if (sink.bytes != expected_bytes) return error.BenchmarkStatus;
            total += sink.bytes;
        } else {
            if (ctx.response.body.len != expected_bytes) {
                return error.BenchmarkStatus;
            }
            total += ctx.response.body.len;
        }
    }
    const elapsed = start.untilNow(io, .awake);
    std.mem.doNotOptimizeAway(total);

    const elapsed_ns = @as(f64, @floatFromInt(elapsed.nanoseconds));
    const count = @as(f64, @floatFromInt(iterations));
    std.debug.print(
        "static {s}: iterations={d} {d:.1} ns/request {d:.0} requests/s {d:.1} MiB/s\n",
        .{
            name,
            iterations,
            elapsed_ns / count,
            count / (elapsed_ns / std.time.ns_per_s),
            @as(f64, @floatFromInt(total)) /
                (elapsed_ns / std.time.ns_per_s) / (1024 * 1024),
        },
    );
}

const Sink = struct {
    bytes: usize = 0,

    fn write(raw: ?*anyopaque, data: []const u8) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(raw orelse
            return error.InvalidWriterState));
        self.bytes += data.len;
    }
};
