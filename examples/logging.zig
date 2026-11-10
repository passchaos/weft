//! Structured request logging with kron.
//!
//! `weft.logging.AccessLog` emits one typed event per request. Installing the
//! same kron owner as the process-wide logger also routes netz's HTTP/1
//! serve-loop diagnostics through kron. Build and run with
//! `zig build run-logging`.
const std = @import("std");
const kron = @import("kron");
const netz = @import("netz");
const weft = @import("weft");

const App = struct {};

fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.json(.{ .message = "hello", .path = ctx.param("name") orelse "/" });
}

fn serveServer(server: *weft.Server(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    const logging = try kron.Logging.create(allocator, io, .{
        .outputs = &.{.{
            .name = "stdout",
            .target = .stdout,
            .mode = .sync,
            .format = .json,
            .filter = "info",
        }},
    });
    defer logging.destroy();

    // Process-wide installation lets netz's HTTP/1 error observer and weft's
    // internal diagnostics use the same owner.
    kron.setGlobalLogging(logging);
    defer kron.clearGlobalLogging();

    var access = weft.logging.AccessLog{ .logging = logging };
    const common = [_]weft.Handler{
        weft.handler(weft.middleware.requestId),
        access.handler(),
    };

    const port: u16 = blk: {
        const text = init.environ_map.get("WEFT_PORT") orelse
            break :blk 8080;
        break :blk std.fmt.parseInt(u16, text, 10) catch 8080;
    };
    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(port) },
            .middleware = &common,
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/", home, .{});
    try server.router().get("/hello/:name", home, .{});

    std.debug.print("weft logging example listening on http://{f}\n", .{
        server.address(),
    });
    try server.serve();
}
