//! Minimal hello-world HTTP/1 server used for framework comparisons.
//!
//! Listens on 127.0.0.1:28081 and serves `GET /` with `Hello, World!` until
//! the process is terminated. Build with `zig build build-hello-server
//! -Doptimize=ReleaseFast`.

const std = @import("std");
const netz = @import("netz");
const weft = @import("weft");

const App = struct {};

fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("Hello, World!");
}

fn serveServer(server: *weft.Server(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.debug.print("server failed: {s}\n", .{@errorName(err)});
            return;
        },
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Match a production multi-core deployment: zio defaults to one executor.
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const executors: u8 = blk: {
        const text = init.environ_map.get("WEFT_EXECUTORS") orelse
            break :blk @intCast(@min(cpu_count, 32));
        break :blk std.fmt.parseInt(u8, text, 10) catch
            @intCast(@min(cpu_count, 32));
    };
    var backend = try netz.runtime.Backend.initWithExecutors(
        allocator,
        executors,
    );
    defer backend.deinit();
    const io = backend.io();

    const port: u16 = blk: {
        const text = init.environ_map.get("WEFT_PORT") orelse
            break :blk 28081;
        break :blk std.fmt.parseInt(u16, text, 10) catch 28081;
    };
    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(port) },
            .limits = .{
                .max_head_bytes = 16 * 1024,
                .max_body_bytes = 64 * 1024,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
                .request_head_timeout = blk: {
                    const text = init.environ_map.get("WEFT_HEAD_TIMEOUT_MS") orelse
                        break :blk .fromSeconds(30);
                    const milliseconds = std.fmt.parseInt(i64, text, 10) catch
                        30000;
                    break :blk if (milliseconds == 0)
                        null
                    else
                        .fromMilliseconds(milliseconds);
                },
            },
            .max_connections = blk: {
                const text = init.environ_map.get("WEFT_CONNECTIONS") orelse
                    break :blk 32;
                break :blk std.fmt.parseInt(usize, text, 10) catch 32;
            },
            .max_requests_per_connection = 1_000_000,
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/", home, .{});

    std.debug.print("weft listening on http://{f}\n", .{server.address()});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    std.Io.sleep(io, .fromSeconds(3600), .awake) catch {};
    server.stop();
    try group.await(io);
}
