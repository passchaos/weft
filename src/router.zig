const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");

pub const Ctx = ctx_mod.Ctx;
pub const Handler = ctx_mod.Handler;
pub const Param = ctx_mod.Param;
pub const max_params = ctx_mod.max_params;

pub const RouteOptions = struct {
    /// Middleware runs in order before the route handler.
    middleware: []const Handler = &.{},
};

pub const Route = struct {
    /// null matches every method.
    method: ?netz.http1.Method,
    pattern: []const u8,
    handler: Handler,
    middleware: []const Handler,
    specificity: u32,
};

pub const Match = struct {
    route: *const Route,
    params: []const Param,
    path: []const u8,
    query: []const u8 = "",
};

const Segment = struct {
    text: []const u8,
    start: usize,
};

const SegmentIterator = struct {
    source: []const u8,
    position: usize = 0,

    fn next(self: *SegmentIterator) ?Segment {
        if (self.position >= self.source.len) return null;
        const start = self.position;
        const end = std.mem.indexOfScalarPos(
            u8,
            self.source,
            self.position,
            '/',
        ) orelse self.source.len;
        self.position = if (end < self.source.len) end + 1 else end;
        return .{ .text = self.source[start..end], .start = start };
    }
};

const Candidate = struct {
    route: ?*const Route = null,
    params: [max_params]Param = undefined,
    count: usize = 0,
    score: u32 = 0,
};

/// A method-and-path router with `:param` captures and a trailing `*` wildcard.
///
/// Routes are stored in registration order. Matching selects the most specific
/// candidate (static > parameter > wildcard), with registration order breaking
/// ties. This keeps the implementation small while giving deterministic
/// precedence.
pub fn Router(comptime H: type) type {
    return struct {
        allocator: std.mem.Allocator,
        routes: std.ArrayListUnmanaged(Route) = .empty,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *@This()) void {
            for (self.routes.items) |route| {
                self.allocator.free(route.pattern);
                self.allocator.free(route.middleware);
            }
            self.routes.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn addRaw(
            self: *@This(),
            method: ?netz.http1.Method,
            pattern: []const u8,
            handler: Handler,
            route_options: RouteOptions,
        ) !void {
            const pattern_copy = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(pattern_copy);
            const middleware_copy = try self.allocator.dupe(
                Handler,
                route_options.middleware,
            );
            errdefer self.allocator.free(middleware_copy);

            try self.routes.append(self.allocator, .{
                .method = method,
                .pattern = pattern_copy,
                .handler = handler,
                .middleware = middleware_copy,
                .specificity = computeSpecificity(pattern),
            });
        }

        pub fn get(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.GET, pattern, ctx_mod.handlerFor(H, f), route_options);
        }

        pub fn post(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.POST, pattern, ctx_mod.handlerFor(H, f), route_options);
        }

        pub fn put(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.PUT, pattern, ctx_mod.handlerFor(H, f), route_options);
        }

        pub fn delete(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.DELETE, pattern, ctx_mod.handlerFor(H, f), route_options);
        }

        pub fn patch(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.PATCH, pattern, ctx_mod.handlerFor(H, f), route_options);
        }

        pub fn head(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.HEAD, pattern, ctx_mod.handlerFor(H, f), route_options);
        }

        pub fn options(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.OPTIONS, pattern, ctx_mod.handlerFor(H, f), route_options);
        }

        /// Register a route for every HTTP method.
        pub fn any(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(null, pattern, ctx_mod.handlerFor(H, f), route_options);
        }

        pub fn match(
            self: *@This(),
            method: netz.http1.Method,
            path: []const u8,
            allocator: std.mem.Allocator,
        ) !?Match {
            var best: ?Candidate = null;
            for (self.routes.items) |*route| {
                if (route.method) |route_method| {
                    if (!std.mem.eql(
                        u8,
                        route_method.string(),
                        method.string(),
                    )) continue;
                }

                var candidate = Candidate{};
                if (!matchRoute(route, path, &candidate)) continue;
                if (best == null or candidate.score > best.?.score) {
                    candidate.route = route;
                    best = candidate;
                }
            }

            const winner = best orelse return null;
            const params = try allocator.dupe(
                Param,
                winner.params[0..winner.count],
            );
            return .{
                .route = winner.route.?,
                .params = params,
                .path = path,
            };
        }
    };
}

fn computeSpecificity(pattern: []const u8) u32 {
    var score: u32 = 0;
    const trimmed = std.mem.trim(u8, pattern, "/");
    var segments = SegmentIterator{ .source = trimmed };
    while (segments.next()) |segment| {
        if (segment.text.len > 0 and segment.text[0] == ':') {
            score += 2;
        } else if (std.mem.eql(u8, segment.text, "*")) {
            score += 1;
        } else {
            score += 4;
        }
    }
    return score;
}

fn matchRoute(
    route: *const Route,
    path: []const u8,
    out: *Candidate,
) bool {
    const pattern = std.mem.trim(u8, route.pattern, "/");
    const target = std.mem.trim(u8, path, "/");
    var pattern_segments = SegmentIterator{ .source = pattern };
    var path_segments = SegmentIterator{ .source = target };

    var count: usize = 0;
    var score: u32 = 0;

    while (true) {
        const pattern_segment = pattern_segments.next();
        const path_segment = path_segments.next();

        if (pattern_segment == null and path_segment == null) break;
        if (pattern_segment == null) return false;

        if (path_segment == null) {
            if (!std.mem.eql(u8, pattern_segment.?.text, "*")) return false;
            if (pattern_segments.next() != null) return false;
            if (count >= max_params) return false;
            out.params[count] = .{ .name = "*", .value = "" };
            count += 1;
            score += 1;
            break;
        }

        const pattern_text = pattern_segment.?.text;
        const path_text = path_segment.?.text;

        if (std.mem.eql(u8, pattern_text, "*")) {
            if (pattern_segments.next() != null) return false;
            if (count >= max_params) return false;
            out.params[count] = .{
                .name = "*",
                .value = target[path_segment.?.start..],
            };
            count += 1;
            score += 1;
            break;
        }

        if (pattern_text.len > 0 and pattern_text[0] == ':') {
            if (path_text.len == 0) return false;
            if (count >= max_params) return false;
            out.params[count] = .{
                .name = pattern_text[1..],
                .value = path_text,
            };
            count += 1;
            score += 2;
            continue;
        }

        if (!std.mem.eql(u8, pattern_text, path_text)) return false;
        score += 4;
    }

    out.count = count;
    out.score = score;
    return true;
}

test "static routes match exact paths" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/", ctx_mod.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/health", ctx_mod.handler(Dummy.handle), .{});

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

    try router.addRaw(.GET, "/users/:id", ctx_mod.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/assets/*", ctx_mod.handler(Dummy.handle), .{});

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

    try router.addRaw(.GET, "/users/:id", ctx_mod.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/users/me", ctx_mod.handler(Dummy.handle), .{});

    const matched = (try router.match(.GET, "/users/me", allocator)).?;
    defer allocator.free(matched.params);
    try std.testing.expectEqualStrings("/users/me", matched.route.pattern);
    try std.testing.expectEqual(@as(usize, 0), matched.params.len);
}
