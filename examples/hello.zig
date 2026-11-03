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

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

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
        },
        .{ .name = "weft" },
    );
    defer server.deinit();

    var auth = weft.middleware.BasicAuth{
        .username = "admin",
        .password = "secret",
        .realm = "weft-example",
    };

    const common = [_]weft.Handler{
        weft.handler(weft.middleware.requestId),
        weft.handler(weft.middleware.serverHeader),
        weft.handler(weft.middleware.log),
    };

    var router = server.router();
    try router.get("/", home, .{ .middleware = &common });
    try router.get("/hello/:name", hello, .{ .middleware = &common });
    try router.get("/assets/*", assets, .{ .middleware = &common });
    try router.get("/admin", admin, .{ .middleware = &.{
        weft.handler(weft.middleware.requestId),
        auth.handler(),
    } });

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
