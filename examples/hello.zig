const std = @import("std");
const netz = @import("netz");
const weft = @import("weft");

const App = struct {
    name: []const u8,
};

fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    try ctx.text(app.name);
}

fn hello(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const name = ctx.param("name") orelse "stranger";
    try ctx.json(.{
        .message = "hello",
        .name = name,
        .query = ctx.queryParam("lang") orelse "en",
    });
}

fn assets(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const path = ctx.param("*") orelse "";
    try ctx.text(path);
}

fn admin(app: *App, ctx: *weft.Ctx) anyerror!void {
    try ctx.json(.{
        .message = "welcome",
        .app = app.name,
    });
}

fn serveServer(server: *weft.Server(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn("server failed: {s}", .{@errorName(err)});
            return;
        },
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Zio executors are most efficient when each one owns several
    // connections; keep the count below the expected concurrency. Override
    // with WEFT_EXECUTORS when the deployment needs a different shape.
    const executors: u8 = blk: {
        const text = init.environ_map.get("WEFT_EXECUTORS") orelse
            break :blk @intCast(@min(std.Thread.getCpuCount() catch 1, 8));
        break :blk std.fmt.parseInt(u8, text, 10) catch
            @intCast(@min(std.Thread.getCpuCount() catch 1, 8));
    };
    var backend = try netz.runtime.Backend.initWithExecutors(
        allocator,
        executors,
    );
    defer backend.deinit();
    const io = backend.io();

    var auth = weft.middleware.BasicAuth{
        .username = "admin",
        .password = "secret",
        .realm = "weft-example",
    };

    // Global middleware runs for every route, including 404 and 405 responses.
    const common = [_]weft.Handler{
        weft.handler(weft.middleware.requestId),
        weft.handler(weft.middleware.serverHeader),
        weft.handler(weft.middleware.securityHeaders),
        weft.handler(weft.middleware.compress),
        weft.handler(weft.middleware.log),
    };

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 16 * 1024,
                .max_body_bytes = 64 * 1024,
                .max_request_arena_bytes = 128 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 4,
            .middleware = &common,
        },
        .{ .name = "weft" },
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/", home, .{});
    try router.get("/hello/:name", hello, .{});
    try router.get("/assets/*", assets, .{});
    try router.get("/admin", admin, .{ .middleware = &.{auth.handler()} });

    const address = server.address();
    std.debug.print("weft listening on http://{f}\n", .{address});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{address.ip4.port},
    );
    defer allocator.free(base);

    try request(allocator, io, base, "/", .{});
    try request(allocator, io, base, "/hello/zig?lang=zh", .{});
    try request(allocator, io, base, "/assets/css/site.css", .{});
    try request(allocator, io, base, "/admin", .{});

    const credentials = try std.fmt.allocPrint(
        allocator,
        "{s}:{s}",
        .{ auth.username, auth.password },
    );
    defer allocator.free(credentials);
    const encoded_len = std.base64.standard.Encoder.calcSize(
        credentials.len,
    );
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, credentials);
    const authorization = try std.fmt.allocPrint(
        allocator,
        "Basic {s}",
        .{encoded},
    );
    defer allocator.free(authorization);

    try request(allocator, io, base, "/admin", .{
        .headers = &.{.{
            .name = "Authorization",
            .value = authorization,
        }},
    });

    server.stop();
    try group.await(io);
}

fn request(
    allocator: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    target: []const u8,
    options: netz.http1.runtime.RequestOptions,
) !void {
    const uri = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, target });
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        options,
        .{ .max_head_bytes = 16 * 1024, .max_body_bytes = 64 * 1024 },
    );
    defer response.deinit(allocator);

    std.debug.print("{s} -> {d} {s}\n", .{
        target,
        response.response.status,
        response.response.body,
    });
}
