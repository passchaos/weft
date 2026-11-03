const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;

const App = struct {};

fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("hello from weft");
}

fn hello(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const name = ctx.param("name") orelse "stranger";
    try ctx.json(.{
        .message = "hello",
        .name = name,
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

test "package: end-to-end HTTP/1 request" {
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
            .max_requests_per_connection = 4,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/", home, .{});
    try router.get("/hello/:name", hello, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/hello/weft",
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
    try std.testing.expectEqualStrings(
        "{\"message\":\"hello\",\"name\":\"weft\"}",
        response.response.body,
    );

    server.stop();
    try group.await(io);
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

test "package: query parameters are parsed" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/search?q=weft&lang=zh",
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
        .query = "q=weft&lang=zh",
        .response = weft.Response.init(arena.allocator(), 1024),
        .final_handler = weft.handler(struct {
            fn handle(ctx: *weft.Ctx) anyerror!void {
                try ctx.text(ctx.queryParam("q") orelse "missing");
            }
        }.handle),
    };

    try context.run();
    try std.testing.expectEqualStrings("weft", context.response.body);
}

const MethodHandlers = struct {
    fn resource(ctx: *weft.Ctx) anyerror!void {
        try ctx.text("resource");
    }

    fn echo(ctx: *weft.Ctx) anyerror!void {
        try ctx.json(.{
            .name = ctx.param("name") orelse "",
            .q = ctx.queryParam("q") orelse "",
        });
    }

    fn tooManyHeaders(ctx: *weft.Ctx) anyerror!void {
        try ctx.setHeader("X-A", "a");
        try ctx.setHeader("X-B", "b");
        try ctx.setHeader("X-C", "c");
        try ctx.text("ok");
    }
};

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

test "package: decoded params and query values" {
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
        },
        .{},
    );
    defer server.deinit();

    try server.router().addRaw(
        .GET,
        "/hello/:name",
        weft.handler(MethodHandlers.echo),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/hello/a%20b?q=hello+world",
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
    try std.testing.expectEqualStrings(
        "{\"name\":\"a b\",\"q\":\"hello world\"}",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: malformed query encoding is a 400" {
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

    try server.router().addRaw(
        .GET,
        "/hello/:name",
        weft.handler(MethodHandlers.echo),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/hello/x?q=%zz",
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
    try std.testing.expectEqual(@as(u16, 400), response.response.status);

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

test "package: HTTP/1.0 responses mirror the request version" {
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

    try server.router().get("/", home, .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{ .version = .http_1_0 },
        .{ .max_head_bytes = 4096, .max_body_bytes = 4096 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(
        netz.http1.Version.http_1_0,
        response.response.version,
    );
    try std.testing.expectEqualStrings(
        "hello from weft",
        response.response.body,
    );

    server.stop();
    try group.await(io);
}

test "package: stop drains an idle keep-alive connection" {
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
                .request_head_timeout = .fromMilliseconds(100),
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const address = server.address();
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // Give the worker time to accept and block waiting for a request head.
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    server.stop();
    try group.await(io);
}

test "package: response header budget failure becomes 500" {
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
                .max_response_headers = 4,
                .max_response_head_bytes = 1024,
            },
            .max_connections = 1,
        },
        .{},
    );
    defer server.deinit();

    try server.router().addRaw(
        .GET,
        "/headers",
        weft.handler(MethodHandlers.tooManyHeaders),
        .{},
    );

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/headers",
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
    try std.testing.expectEqual(@as(u16, 500), response.response.status);

    server.stop();
    try group.await(io);
}
