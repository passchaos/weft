const std = @import("std");
const netz = @import("netz");
const router_mod = @import("router.zig");
const ctx_mod = @import("ctx.zig");
const handler_mod = @import("handler.zig");

const Router = router_mod.Router;
const RouteOptions = router_mod.RouteOptions;
const GroupOptions = router_mod.GroupOptions;
const Route = router_mod.Route;
const Match = router_mod.Match;
const Prepared = router_mod.Prepared;
const AllowedMethods = router_mod.AllowedMethods;
const Resolution = router_mod.Resolution;
const max_path_segments = router_mod.max_path_segments;
const max_allowed_methods = router_mod.max_allowed_methods;
const Ctx = ctx_mod.Ctx;
const Handler = handler_mod.Handler;
const Param = handler_mod.Param;
const max_params = handler_mod.max_params;

test "static routes match exact paths" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/", handler_mod.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/health", handler_mod.handler(Dummy.handle), .{});

    const root = (try router.match(.GET, "/", allocator)).?;
    defer allocator.free(root.params);
    try std.testing.expectEqualStrings("/", root.route.pattern);
    try std.testing.expectEqual(@as(usize, 0), root.params.len);

    const health = (try router.match(.GET, "/health", allocator)).?;
    defer allocator.free(health.params);
    try std.testing.expectEqualStrings("/health", health.route.pattern);

    try std.testing.expect((try router.match(.POST, "/health", allocator)) == null);
}

test "parameter and wildcard captures" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/users/:id", handler_mod.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/assets/*", handler_mod.handler(Dummy.handle), .{});

    const user = (try router.match(.GET, "/users/42", allocator)).?;
    defer allocator.free(user.params);
    try std.testing.expectEqual(@as(usize, 1), user.params.len);
    try std.testing.expectEqualStrings("id", user.params[0].name);
    try std.testing.expectEqualStrings("42", user.params[0].value);

    const asset = (try router.match(.GET, "/assets/js/app.js", allocator)).?;
    defer allocator.free(asset.params);
    try std.testing.expectEqual(@as(usize, 1), asset.params.len);
    try std.testing.expectEqualStrings("*", asset.params[0].name);
    try std.testing.expectEqualStrings("js/app.js", asset.params[0].value);
}

test "static routes win over parameter routes" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/users/:id", handler_mod.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/users/me", handler_mod.handler(Dummy.handle), .{});

    const matched = (try router.match(.GET, "/users/me", allocator)).?;
    defer allocator.free(matched.params);
    try std.testing.expectEqualStrings("/users/me", matched.route.pattern);
    try std.testing.expectEqual(@as(usize, 0), matched.params.len);
}

test "leftmost static segment wins independent of registration order" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/a/:b/c", handler_mod.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/a/b/:c", handler_mod.handler(Dummy.handle), .{});

    const matched = (try router.match(.GET, "/a/b/c", allocator)).?;
    defer allocator.free(matched.params);
    try std.testing.expectEqualStrings("/a/b/:c", matched.route.pattern);
    try std.testing.expectEqualStrings("c", matched.params[0].value);
}

test "method mismatch returns allowed methods and HEAD falls back to GET" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/resource", handler_mod.handler(Dummy.handle), .{});
    try router.addRaw(.POST, "/resource", handler_mod.handler(Dummy.handle), .{});
    try router.addRaw(.DELETE, "/other", handler_mod.handler(Dummy.handle), .{});

    const head = (try router.resolve(.HEAD, "/resource", allocator)).matched;
    defer allocator.free(head.params);
    try std.testing.expectEqual(netz.http1.Method.GET, head.route.method.?);

    const denied = try router.resolve(.PUT, "/resource", allocator);
    try std.testing.expect(denied == .method_not_allowed);
    try std.testing.expect(denied.method_not_allowed.contains(.GET));
    try std.testing.expect(denied.method_not_allowed.contains(.HEAD));
    try std.testing.expect(denied.method_not_allowed.contains(.POST));
    try std.testing.expect(denied.method_not_allowed.contains(.OPTIONS));

    const missing = try router.resolve(.PUT, "/missing", allocator);
    try std.testing.expect(missing == .not_found);
}

test "invalid and conflicting registrations are rejected" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/users/:id", handler_mod.handler(Dummy.handle), .{});
    try std.testing.expectError(
        error.DuplicateRoute,
        router.addRaw(.GET, "/users/:id", handler_mod.handler(Dummy.handle), .{}),
    );
    try std.testing.expectError(
        error.RouteConflict,
        router.addRaw(null, "/users/:id", handler_mod.handler(Dummy.handle), .{}),
    );
    try std.testing.expectError(
        error.InvalidPattern,
        router.addRaw(.GET, "/users/*/edit", handler_mod.handler(Dummy.handle), .{}),
    );
    try std.testing.expectError(
        error.InvalidPattern,
        router.addRaw(.GET, "users", handler_mod.handler(Dummy.handle), .{}),
    );
    try std.testing.expectError(
        error.InvalidPattern,
        router.addRaw(.GET, "//users", handler_mod.handler(Dummy.handle), .{}),
    );
}

test "route groups compose prefixes and middleware" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }

        fn middleware(ctx: *Ctx) anyerror!void {
            try ctx.next();
        }
    };

    var api = try router.group("/api", .{
        .middleware = &.{handler_mod.handler(Dummy.middleware)},
    });
    try api.addRaw(.GET, "/users/:id", handler_mod.handler(Dummy.handle), .{});

    var v1 = try api.group("/v1", .{
        .middleware = &.{handler_mod.handler(Dummy.middleware)},
    });
    try v1.addRaw(.GET, "/health", handler_mod.handler(Dummy.handle), .{});

    const user = (try router.match(.GET, "/api/users/42", allocator)).?;
    defer allocator.free(user.params);
    try std.testing.expectEqualStrings("/api/users/:id", user.route.pattern);
    try std.testing.expectEqual(@as(usize, 1), user.route.middleware.len);

    const health = (try router.match(.GET, "/api/v1/health", allocator)).?;
    defer allocator.free(health.params);
    try std.testing.expectEqualStrings("/api/v1/health", health.route.pattern);
    try std.testing.expectEqual(@as(usize, 2), health.route.middleware.len);

    try std.testing.expectError(
        error.InvalidPattern,
        router.group("api", .{}),
    );
    try std.testing.expectError(
        error.InvalidPattern,
        router.group("/api/:version", .{}),
    );
    try std.testing.expectError(
        error.InvalidPattern,
        api.addRaw(.GET, "", handler_mod.handler(Dummy.handle), .{}),
    );
}

test "lookup cost stays flat across many routes" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    var index: usize = 0;
    while (index < 512) : (index += 1) {
        const pattern = try std.fmt.allocPrint(
            allocator,
            "/api/v1/resource{d}",
            .{index},
        );
        defer allocator.free(pattern);
        try router.addRaw(.GET, pattern, handler_mod.handler(Dummy.handle), .{});
    }

    const matched = (try router.match(
        .GET,
        "/api/v1/resource511",
        allocator,
    )).?;
    defer allocator.free(matched.params);
    try std.testing.expectEqualStrings(
        "/api/v1/resource511",
        matched.route.pattern,
    );
}

test "failed registration leaves no route in the trie" {
    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    const testImpl = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var router = Router(void).init(allocator);
            defer router.deinit();

            router.addRaw(
                .GET,
                "/users/:id",
                handler_mod.handler(Dummy.handle),
                .{},
            ) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                // The route is freed by the error path, so the trie and the
                // ownership list must both be empty afterwards.
                try std.testing.expectEqual(
                    @as(usize, 0),
                    router.debugRouteCount(),
                );
                try std.testing.expectEqual(
                    @as(usize, 0),
                    router.all_routes.items.len,
                );
                return err;
            };

            try std.testing.expectEqual(
                @as(usize, 1),
                router.debugRouteCount(),
            );
            try std.testing.expectEqual(
                @as(usize, 1),
                router.all_routes.items.len,
            );
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testImpl.run,
        .{},
    );
}

test "failed wildcard registration leaves no route in the trie" {
    const testImpl = struct {
        const Dummy = struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        };
        const middleware = [_]Handler{handler_mod.handler(Dummy.handle)};

        fn run(allocator: std.mem.Allocator) !void {
            var router = Router(void).init(allocator);
            defer router.deinit();

            router.addRaw(
                null,
                "/assets/*",
                handler_mod.handler(Dummy.handle),
                .{ .middleware = &middleware },
            ) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(
                    @as(usize, 0),
                    router.debugRouteCount(),
                );
                try std.testing.expectEqual(
                    @as(usize, 0),
                    router.all_routes.items.len,
                );
                return err;
            };

            try std.testing.expectEqual(
                @as(usize, 1),
                router.debugRouteCount(),
            );
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testImpl.run,
        .{},
    );
}

test "failed group registration releases ownership" {
    const testImpl = struct {
        const Dummy = struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        };
        const middleware = [_]Handler{handler_mod.handler(Dummy.handle)};

        fn run(allocator: std.mem.Allocator) !void {
            var router = Router(void).init(allocator);
            defer router.deinit();

            var api = try router.group("/api", .{ .middleware = &middleware });
            try api.addRaw(
                .GET,
                "/users/:id",
                handler_mod.handler(Dummy.handle),
                .{},
            );
            try std.testing.expectEqual(
                @as(usize, 1),
                router.all_routes.items.len,
            );
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testImpl.run,
        .{},
    );
}
