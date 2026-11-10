const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const MethodHandlers = support.MethodHandlers;
const OrderState = support.OrderState;
const customMethodNotAllowed = support.customMethodNotAllowed;
const customNotFound = support.customNotFound;
const echoJson = support.echoJson;
const home = support.home;
const serveServer = support.serveServer;

test "package: router selects static, parameter, and wildcard routes" {
    const allocator = std.testing.allocator;
    var router = weft.Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *weft.Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/users/me", weft.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/users/:id", weft.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/assets/*", weft.handler(Dummy.handle), .{});

    const me = (try router.match(.GET, "/users/me", allocator)).?;
    defer allocator.free(me.params);
    try std.testing.expectEqualStrings("/users/me", me.route.pattern);

    const user = (try router.match(.GET, "/users/42", allocator)).?;
    defer allocator.free(user.params);
    try std.testing.expectEqualStrings("/users/:id", user.route.pattern);
    try std.testing.expectEqualStrings("42", user.params[0].value);

    const asset = (try router.match(.GET, "/assets/a/b", allocator)).?;
    defer allocator.free(asset.params);
    try std.testing.expectEqualStrings("a/b", asset.params[0].value);
}

test "package: middleware order, short-circuit, and locals" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const State = struct {
        fn before(ctx: *weft.Ctx) anyerror!void {
            try ctx.set(u32, 7);
            try ctx.next();
        }

        fn after(ctx: *weft.Ctx) anyerror!void {
            const value = ctx.get(u32) orelse 0;
            try ctx.setHeader("X-Test", "ok");
            _ = value;
            try ctx.next();
        }

        fn stop(ctx: *weft.Ctx) anyerror!void {
            ctx.setStatus(403);
            try ctx.text("stopped");
        }

        fn handler(ctx: *weft.Ctx) anyerror!void {
            const value = ctx.get(u32) orelse 0;
            try ctx.text(try std.fmt.allocPrint(
                ctx.arena,
                "value={d}",
                .{value},
            ));
        }
    };

    const response = weft.Response.init(arena.allocator(), 1024);
    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var context = weft.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = response,
        .middleware = &.{
            weft.handler(State.before),
            weft.handler(State.after),
        },
        .final_handler = weft.handler(State.handler),
    };

    try context.run();
    try std.testing.expectEqualStrings("value=7", context.response.body);
    try std.testing.expect(context.response.hasHeader("x-test"));

    const stopped = weft.Response.init(arena.allocator(), 1024);
    var stopped_context = weft.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = stopped,
        .middleware = &.{weft.handler(State.stop)},
        .final_handler = weft.handler(State.handler),
    };
    try stopped_context.run();
    try std.testing.expectEqual(@as(u16, 403), stopped_context.response.status);
    try std.testing.expectEqualStrings("stopped", stopped_context.response.body);
}

test "package: next may be called at most once per handler" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Bad = struct {
        fn twice(ctx: *weft.Ctx) anyerror!void {
            try ctx.next();
            try ctx.next();
        }

        fn final(ctx: *weft.Ctx) anyerror!void {
            try ctx.text("ok");
        }
    };

    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var context = weft.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = weft.Response.init(arena.allocator(), 1024),
        .middleware = &.{weft.handler(Bad.twice)},
        .final_handler = weft.handler(Bad.final),
    };

    try std.testing.expectError(error.NextNotAllowed, context.run());
    try std.testing.expectEqualStrings("ok", context.response.body);
}

test "package: 405, automatic OPTIONS, and HEAD fallback" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 2,
            .max_requests_per_connection = 4,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.addRaw(
        .GET,
        "/resource",
        weft.handler(MethodHandlers.resource),
        .{},
    );
    try router.addRaw(
        .POST,
        "/resource",
        weft.handler(MethodHandlers.resource),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{server.address().ip4.port},
    );
    defer allocator.free(base);
    const uri = try std.fmt.allocPrint(allocator, "{s}/resource", .{base});
    defer allocator.free(uri);

    var put_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .method = .PUT },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer put_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 405), put_response.response.status);
    const allow = put_response.response.header("allow").?;
    try std.testing.expect(std.mem.indexOf(u8, allow, "GET") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "POST") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "OPTIONS") != null);

    var options_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .method = .OPTIONS },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer options_response.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 204),
        options_response.response.status,
    );
    try std.testing.expect(
        options_response.response.header("allow") != null,
    );

    var head_response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .method = .HEAD },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer head_response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), head_response.response.status);
    try std.testing.expectEqualStrings("", head_response.response.body);

    server.stop();
    try group.await(io);
}

test "package: global middleware covers 404 responses" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .middleware = &.{weft.handler(weft.middleware.serverHeader)},
        },
        .{},
    );
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/missing",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), response.response.status);
    try std.testing.expectEqualStrings(
        "weft",
        response.response.header("server").?,
    );

    server.stop();
    try group.await(io);
}

test "package: OPTIONS star advertises router methods" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/", home, .{});
    try router.post("/echo", echoJson, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    var client = try netz.http1.runtime.Client.connect(
        allocator,
        io,
        server.address(),
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer client.close();

    var response = try client.request(.{
        .method = .OPTIONS,
        .target = "*",
        .host = "localhost",
    });
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 204), response.response.status);
    const allow = response.response.header("allow").?;
    try std.testing.expect(std.mem.indexOf(u8, allow, "GET") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "POST") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "OPTIONS") != null);

    server.stop();
    try group.await(io);
}

test "package: custom not-found and method-not-allowed handlers" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .not_found = weft.handler(customNotFound),
            .method_not_allowed = weft.handler(customMethodNotAllowed),
        },
        .{},
    );
    defer server.deinit();

    try server.router().get("/only", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const base = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{server.address().ip4.port},
    );
    defer allocator.free(base);

    const missing_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/missing",
        .{base},
    );
    defer allocator.free(missing_uri);
    var missing = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        missing_uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), missing.response.status);
    try std.testing.expectEqualStrings(
        "{\"custom\":\"not_found\",\"status\":404}",
        missing.response.body,
    );

    const only_uri = try std.fmt.allocPrint(
        allocator,
        "{s}/only",
        .{base},
    );
    defer allocator.free(only_uri);
    var denied = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        only_uri,
        .{ .method = .POST },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer denied.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 405), denied.response.status);
    try std.testing.expect(denied.response.header("allow") != null);
    try std.testing.expectEqualStrings(
        "{\"custom\":\"method_not_allowed\",\"allow\":\"GET, HEAD, OPTIONS\"}",
        denied.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: route middleware runs after application middleware" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .middleware = &.{weft.handler(OrderState.app)},
        },
        .{},
    );
    defer server.deinit();
    try server.router().get("/order", OrderState.finalRoute, .{
        .middleware = &.{weft.handler(OrderState.route)},
    });

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/order",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);
    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings("ok", response.response.body);
    try std.testing.expectEqualStrings(
        "arh",
        response.response.header("x-order").?,
    );

    server.stop();
    try group.await(io);
}
