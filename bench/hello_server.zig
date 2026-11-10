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

    // The comparison runs 32 keep-alive connections. Zio executors are most
    // efficient when each one owns several connections; sizing the executor
    // count to the connection count leaves every executor mostly parked and
    // adds wake-up latency to the tail. Eight executors keep the server
    // saturated while staying below the connection count. Override with
    // WEFT_EXECUTORS for other concurrency levels.
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const executors: u8 = blk: {
        const text = init.environ_map.get("WEFT_EXECUTORS") orelse
            break :blk @intCast(@min(cpu_count, 8));
        break :blk std.fmt.parseInt(u8, text, 10) catch
            @intCast(@min(cpu_count, 8));
    };
    var backend: netz.runtime.Backend = undefined;
    var threaded: std.Io.Threaded = undefined;
    var use_threaded = false;
    const io: std.Io = blk: {
        const kind = init.environ_map.get("WEFT_IO") orelse "zio";
        if (std.mem.eql(u8, kind, "threaded")) {
            use_threaded = true;
            const async_limit: std.Io.Limit = limit_blk: {
                const text = init.environ_map.get("WEFT_IO_ASYNC") orelse
                    break :limit_blk .unlimited;
                if (std.mem.eql(u8, text, "unlimited"))
                    break :limit_blk .unlimited;
                const count = std.fmt.parseInt(usize, text, 10) catch
                    break :limit_blk .unlimited;
                break :limit_blk .limited(count);
            };
            threaded = .init(allocator, .{ .async_limit = async_limit });
            break :blk threaded.io();
        }
        backend = try netz.runtime.Backend.initWithExecutors(
            allocator,
            executors,
        );
        break :blk backend.io();
    };
    defer if (use_threaded) threaded.deinit() else backend.deinit();

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
