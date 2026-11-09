const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const openapi_mod = @import("openapi.zig");

pub const Ctx = ctx_mod.Ctx;
pub const Handler = ctx_mod.Handler;
pub const Param = ctx_mod.Param;
pub const max_params = ctx_mod.max_params;

/// Maximum number of path segments accepted by the matcher. The bound keeps
/// recursive traversal and node teardown stack-safe for hostile targets.
pub const max_path_segments = 128;

/// Maximum methods stored in one `Allow` field.
pub const max_allowed_methods = 16;

pub const RouteOptions = struct {
    /// Middleware runs in order before the route handler.
    middleware: []const Handler = &.{},
    /// Read the request body incrementally and deliver it through
    /// `Ctx.bodyReader()` on an HTTP/1 connection. Handlers on streaming
    /// routes must consume or ignore the reader; the server drains any
    /// remainder before writing the response.
    streaming: bool = false,
    /// Optional per-route request-body budget. Null inherits
    /// `Limits.max_body_bytes`. A smaller value rejects buffered bodies with
    /// `413` and bounds streaming reads through `Ctx.bodyReader()` and
    /// `Ctx.readBody()`.
    max_body_bytes: ?usize = null,
    /// Optional per-route handler budget. Null inherits
    /// `Limits.request_timeout`; zero is rejected by the router.
    timeout: ?std.Io.Duration = null,
    /// Optional OpenAPI operation metadata used by `Router.openapiRoutes` and
    /// `openapi.Document`.
    openapi: ?openapi_mod.Operation = null,
};

pub const GroupOptions = struct {
    /// Middleware runs before every route registered through the group.
    middleware: []const Handler = &.{},
};

pub const Route = struct {
    /// null matches every method.
    method: ?netz.http1.Method,
    pattern: []const u8,
    handler: Handler,
    middleware: []const Handler,
    /// True when the server should stream the request body to the handler.
    streaming: bool = false,
    /// Optional per-route body budget; null inherits the server limit.
    max_body_bytes: ?usize = null,
    /// Optional per-route handler budget; null inherits the server timeout.
    timeout: ?std.Io.Duration = null,
    /// Optional OpenAPI operation metadata.
    openapi: ?openapi_mod.Operation = null,
    /// Segment weights used for diagnostics and tie-breaking documentation.
    /// Matching itself walks the trie, where precedence is structural.
    specificity: u32,
    /// Number of `:param` and `*` captures in `pattern`.
    capture_count: usize,
    /// Capture names in match order, borrowed from `pattern`.
    capture_names: []const []const u8 = &.{},
};

pub const Match = struct {
    route: *const Route,
    /// Raw (not percent-decoded) path capture values. `Ctx.param` exposes
    /// decoded values.
    params: []const Param,
    path: []const u8,
    query: []const u8 = "",

    pub fn deinit(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.params);
    }
};

/// Methods that match a path but not the requested method. The server turns
/// this into `405 Method Not Allowed` with an `Allow` field.
pub const AllowedMethods = struct {
    methods: [max_allowed_methods]netz.http1.Method = undefined,
    len: usize = 0,

    pub fn add(self: *AllowedMethods, method: netz.http1.Method) void {
        self.addRaw(method);
        if (method == .GET) self.addRaw(.HEAD);
        // The server answers OPTIONS for any matched path.
        self.addRaw(.OPTIONS);
    }

    pub fn contains(self: *const AllowedMethods, method: netz.http1.Method) bool {
        for (self.methods[0..self.len]) |candidate| {
            if (methodEqual(candidate, method)) return true;
        }
        return false;
    }

    pub fn slice(self: *const AllowedMethods) []const netz.http1.Method {
        return self.methods[0..self.len];
    }

    /// Render the field value, e.g. `GET, HEAD, OPTIONS`.
    pub fn value(self: *const AllowedMethods, allocator: std.mem.Allocator) ![]const u8 {
        var names: [max_allowed_methods][]const u8 = undefined;
        for (self.methods[0..self.len], 0..) |method, index| {
            names[index] = method.string();
        }
        return std.mem.join(allocator, ", ", names[0..self.len]);
    }

    fn addRaw(self: *AllowedMethods, method: netz.http1.Method) void {
        if (self.contains(method)) return;
        if (self.len >= max_allowed_methods) return;
        self.methods[self.len] = method;
        self.len += 1;
    }
};

pub const Resolution = union(enum) {
    matched: Match,
    method_not_allowed: AllowedMethods,
    not_found,
};

const Node = struct {
    static_children: std.StringHashMapUnmanaged(*Node) = .empty,
    /// Fast path for the common case of exactly one static child. When set,
    /// `static_children` is empty and `single_key` owns the child's name.
    single_key: ?[]const u8 = null,
    single_child: ?*Node = null,
    param: ?*Node = null,
    routes: std.ArrayListUnmanaged(*Route) = .empty,
    wildcard_routes: std.ArrayListUnmanaged(*Route) = .empty,
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

const Captures = struct {
    values: [max_params][]const u8 = undefined,
    count: usize = 0,
};

/// A route lookup performed before the request body is read.
///
/// Adapters use `route.streaming` to decide whether to expose a body reader,
/// then pass the same value to dispatch so the trie is walked once per
/// request. `route` is null when nothing matched; `allowed` then lists the
/// methods registered on the matched path.
pub const Prepared = struct {
    route: ?*const Route = null,
    captures: Captures = .{},
    allowed: AllowedMethods = .{},
};

const PatternInfo = struct {
    captures: usize,
    segments: usize,
};

/// A method-and-path router with `:param` captures and a trailing `*` wildcard.
///
/// Routes are indexed by a segment trie. At every segment the matcher prefers
/// a static child, then a parameter child, then a wildcard. This makes lookup
/// proportional to the number of path segments instead of the number of
/// registered routes, while preserving the usual static > parameter > wildcard
/// precedence. Registration order only matters for otherwise identical routes,
/// which are rejected as duplicates.
///
/// Register routes before starting the server. Matching is read-only, but the
/// router itself is not internally synchronized against concurrent registration.
pub fn Router(comptime H: type) type {
    return struct {
        const Self = @This();

        const GroupStorage = struct {
            prefix: []const u8,
            middleware: []const Handler,
        };

        allocator: std.mem.Allocator,
        root: Node = .{},
        all_routes: std.ArrayListUnmanaged(*Route) = .empty,
        groups: std.ArrayListUnmanaged(*GroupStorage) = .empty,
        max_middleware: usize = 32,

        /// A prefix and middleware scope returned by `Router.group`.
        pub const Group = struct {
            owner: *Self,
            prefix: []const u8,
            middleware: []const Handler,

            pub fn addRaw(
                self: Group,
                method: ?netz.http1.Method,
                pattern: []const u8,
                handler: Handler,
                route_options: RouteOptions,
            ) !void {
                if (pattern.len == 0) return error.InvalidPattern;
                const combined_pattern = try joinPath(
                    self.owner.allocator,
                    self.prefix,
                    pattern,
                );
                defer self.owner.allocator.free(combined_pattern);
                const combined_middleware = try concatHandlers(
                    self.owner.allocator,
                    self.middleware,
                    route_options.middleware,
                );
                defer self.owner.allocator.free(combined_middleware);

                try self.owner.addRaw(
                    method,
                    combined_pattern,
                    handler,
                    .{
                        .middleware = combined_middleware,
                        .streaming = route_options.streaming,
                        .max_body_bytes = route_options.max_body_bytes,
                        .timeout = route_options.timeout,
                        .openapi = route_options.openapi,
                    },
                );
            }

            pub fn get(
                self: Group,
                pattern: []const u8,
                comptime f: fn (*H, *Ctx) anyerror!void,
                route_options: RouteOptions,
            ) !void {
                return self.addRaw(
                    .GET,
                    pattern,
                    ctx_mod.handlerFor(H, f),
                    route_options,
                );
            }

            pub fn post(
                self: Group,
                pattern: []const u8,
                comptime f: fn (*H, *Ctx) anyerror!void,
                route_options: RouteOptions,
            ) !void {
                return self.addRaw(
                    .POST,
                    pattern,
                    ctx_mod.handlerFor(H, f),
                    route_options,
                );
            }

            pub fn put(
                self: Group,
                pattern: []const u8,
                comptime f: fn (*H, *Ctx) anyerror!void,
                route_options: RouteOptions,
            ) !void {
                return self.addRaw(
                    .PUT,
                    pattern,
                    ctx_mod.handlerFor(H, f),
                    route_options,
                );
            }

            pub fn delete(
                self: Group,
                pattern: []const u8,
                comptime f: fn (*H, *Ctx) anyerror!void,
                route_options: RouteOptions,
            ) !void {
                return self.addRaw(
                    .DELETE,
                    pattern,
                    ctx_mod.handlerFor(H, f),
                    route_options,
                );
            }

            pub fn patch(
                self: Group,
                pattern: []const u8,
                comptime f: fn (*H, *Ctx) anyerror!void,
                route_options: RouteOptions,
            ) !void {
                return self.addRaw(
                    .PATCH,
                    pattern,
                    ctx_mod.handlerFor(H, f),
                    route_options,
                );
            }

            pub fn head(
                self: Group,
                pattern: []const u8,
                comptime f: fn (*H, *Ctx) anyerror!void,
                route_options: RouteOptions,
            ) !void {
                return self.addRaw(
                    .HEAD,
                    pattern,
                    ctx_mod.handlerFor(H, f),
                    route_options,
                );
            }

            pub fn options(
                self: Group,
                pattern: []const u8,
                comptime f: fn (*H, *Ctx) anyerror!void,
                route_options: RouteOptions,
            ) !void {
                return self.addRaw(
                    .OPTIONS,
                    pattern,
                    ctx_mod.handlerFor(H, f),
                    route_options,
                );
            }

            pub fn any(
                self: Group,
                pattern: []const u8,
                comptime f: fn (*H, *Ctx) anyerror!void,
                route_options: RouteOptions,
            ) !void {
                return self.addRaw(
                    null,
                    pattern,
                    ctx_mod.handlerFor(H, f),
                    route_options,
                );
            }

            /// Create a nested group whose prefix and middleware extend this
            /// group.
            pub fn group(
                self: Group,
                prefix: []const u8,
                group_options: GroupOptions,
            ) !Group {
                return self.owner.groupWith(
                    self.prefix,
                    self.middleware,
                    prefix,
                    group_options.middleware,
                );
            }
        };

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        pub fn initWithMaxMiddleware(
            allocator: std.mem.Allocator,
            max_middleware: usize,
        ) @This() {
            return .{
                .allocator = allocator,
                .max_middleware = max_middleware,
            };
        }

        /// Create a route group with a shared prefix and middleware chain.
        pub fn group(
            self: *@This(),
            prefix: []const u8,
            group_options: GroupOptions,
        ) !Group {
            return self.groupWith("", &.{}, prefix, group_options.middleware);
        }

        fn groupWith(
            self: *@This(),
            base_prefix: []const u8,
            base_middleware: []const Handler,
            prefix: []const u8,
            middleware: []const Handler,
        ) !Group {
            const normalized = try normalizeGroupPrefix(prefix);
            const combined_prefix = try joinPath(
                self.allocator,
                base_prefix,
                normalized,
            );
            errdefer self.allocator.free(combined_prefix);
            const combined_middleware = try concatHandlers(
                self.allocator,
                base_middleware,
                middleware,
            );
            errdefer self.allocator.free(combined_middleware);

            const storage = try self.allocator.create(GroupStorage);
            errdefer self.allocator.destroy(storage);
            storage.* = .{
                .prefix = combined_prefix,
                .middleware = combined_middleware,
            };
            try self.groups.append(self.allocator, storage);

            return .{
                .owner = self,
                .prefix = storage.prefix,
                .middleware = storage.middleware,
            };
        }

        pub fn deinit(self: *@This()) void {
            for (self.all_routes.items) |route| {
                self.allocator.free(route.pattern);
                self.allocator.free(route.middleware);
                if (route.capture_names.len != 0) {
                    self.allocator.free(route.capture_names);
                }
                self.allocator.destroy(route);
            }
            self.all_routes.deinit(self.allocator);
            for (self.groups.items) |storage| {
                self.allocator.free(storage.prefix);
                self.allocator.free(storage.middleware);
                self.allocator.destroy(storage);
            }
            self.groups.deinit(self.allocator);
            self.deinitNode(&self.root);
            self.* = undefined;
        }

        pub fn addRaw(
            self: *@This(),
            method: ?netz.http1.Method,
            pattern: []const u8,
            handler: Handler,
            route_options: RouteOptions,
        ) !void {
            const info = try validatePattern(pattern);
            if (route_options.middleware.len > self.max_middleware) {
                return error.TooMuchMiddleware;
            }
            if (route_options.timeout) |timeout| {
                if (timeout.nanoseconds <= 0) return error.InvalidTimeout;
            }
            if (route_options.max_body_bytes) |limit| {
                if (limit == 0) return error.InvalidBodyLimit;
            }
            try self.checkConflict(pattern, method);

            const route = try self.allocator.create(Route);
            errdefer self.allocator.destroy(route);
            const pattern_copy = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(pattern_copy);
            const middleware_copy = try self.allocator.dupe(
                Handler,
                route_options.middleware,
            );
            errdefer self.allocator.free(middleware_copy);

            var capture_names: []const []const u8 = &.{};
            // Function-scoped so a later allocation failure also releases the
            // names array; a block-scoped `errdefer` would end with the block.
            errdefer if (capture_names.len != 0) {
                self.allocator.free(capture_names);
            };
            if (info.captures != 0) {
                const names = try self.allocator.alloc(
                    []const u8,
                    info.captures,
                );
                var capture_index: usize = 0;
                var name_segments = SegmentIterator{
                    .source = std.mem.trim(u8, pattern_copy, "/"),
                };
                while (name_segments.next()) |segment| {
                    if (segment.text[0] == ':') {
                        names[capture_index] = segment.text[1..];
                        capture_index += 1;
                    } else if (std.mem.eql(u8, segment.text, "*")) {
                        names[capture_index] = "*";
                        capture_index += 1;
                    }
                }
                capture_names = names;
            }

            route.* = .{
                .method = method,
                .pattern = pattern_copy,
                .handler = handler,
                .middleware = middleware_copy,
                .streaming = route_options.streaming,
                .max_body_bytes = route_options.max_body_bytes,
                .timeout = route_options.timeout,
                .openapi = route_options.openapi,
                .specificity = computeSpecificity(pattern),
                .capture_count = info.captures,
                .capture_names = capture_names,
            };

            // Register ownership before touching the trie so a failed node
            // append cannot leave a dangling route pointer behind.
            try self.all_routes.append(self.allocator, route);
            errdefer _ = self.all_routes.pop();

            const trimmed = std.mem.trim(u8, pattern_copy, "/");
            var node = &self.root;
            var segments = SegmentIterator{ .source = trimmed };
            var wildcard = false;
            while (segments.next()) |segment| {
                if (std.mem.eql(u8, segment.text, "*")) {
                    try node.wildcard_routes.append(self.allocator, route);
                    wildcard = true;
                    break;
                }
                if (segment.text[0] == ':') {
                    if (node.param == null) {
                        node.param = try self.createNode();
                    }
                    node = node.param.?;
                } else {
                    node = try self.staticChild(node, segment.text);
                }
            }

            if (!wildcard) {
                try node.routes.append(self.allocator, route);
            }
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

        /// Match a method and path, distinguishing a missing path from a
        /// present path with no matching method.
        pub fn resolve(
            self: *@This(),
            method: netz.http1.Method,
            path: []const u8,
            allocator: std.mem.Allocator,
        ) !Resolution {
            const source = if (std.mem.eql(u8, path, "*"))
                ""
            else if (path.len > 0 and path[0] == '/')
                std.mem.trim(u8, path, "/")
            else
                return .not_found;

            var captures = Captures{};
            var allowed = AllowedMethods{};
            if (self.matchNode(
                &self.root,
                source,
                0,
                0,
                method,
                &captures,
                &allowed,
            )) |route| {
                return .{ .matched = try buildMatch(
                    route,
                    &captures,
                    allocator,
                    path,
                ) };
            }

            // HEAD falls back to GET, matching the HTTP semantics that a GET
            // resource is readable without its representation.
            if (method == .HEAD) {
                var get_captures = Captures{};
                if (self.matchNode(
                    &self.root,
                    source,
                    0,
                    0,
                    .GET,
                    &get_captures,
                    &allowed,
                )) |route| {
                    return .{ .matched = try buildMatch(
                        route,
                        &get_captures,
                        allocator,
                        path,
                    ) };
                }
            }

            if (allowed.len > 0) return .{ .method_not_allowed = allowed };
            return .not_found;
        }

        /// Resolve the route without allocating. Adapters call this before
        /// reading the body and pass the result to dispatch.
        pub fn prepare(
            self: *@This(),
            method: netz.http1.Method,
            path: []const u8,
            out: *Prepared,
        ) void {
            // Only the counts need clearing; capture and method arrays are
            // written before they are read.
            out.route = null;
            out.allowed.len = 0;
            out.captures.count = 0;
            const source = if (std.mem.eql(u8, path, "*"))
                ""
            else if (path.len > 0 and path[0] == '/')
                std.mem.trim(u8, path, "/")
            else
                return;

            if (self.matchNode(
                &self.root,
                source,
                0,
                0,
                method,
                &out.captures,
                &out.allowed,
            )) |route| {
                out.route = route;
                return;
            }

            // HEAD falls back to GET, matching the HTTP semantics that a GET
            // resource is readable without its representation.
            if (method == .HEAD) {
                var get_captures = Captures{};
                if (self.matchNode(
                    &self.root,
                    source,
                    0,
                    0,
                    .GET,
                    &get_captures,
                    &out.allowed,
                )) |route| {
                    out.route = route;
                    out.captures = get_captures;
                    return;
                }
            }
        }

        /// Cheap check for whether the matched route opted into streaming.
        /// Performs no allocation; adapters use it to decide whether to expose
        /// a body reader.
        pub fn isStreaming(
            self: *@This(),
            method: netz.http1.Method,
            path: []const u8,
        ) bool {
            const source = if (std.mem.eql(u8, path, "*"))
                ""
            else if (path.len > 0 and path[0] == '/')
                std.mem.trim(u8, path, "/")
            else
                return false;

            var captures = Captures{};
            var allowed = AllowedMethods{};
            if (self.matchNode(
                &self.root,
                source,
                0,
                0,
                method,
                &captures,
                &allowed,
            )) |route| return route.streaming;

            if (method == .HEAD) {
                var head_captures = Captures{};
                var head_allowed = AllowedMethods{};
                if (self.matchNode(
                    &self.root,
                    source,
                    0,
                    0,
                    .GET,
                    &head_captures,
                    &head_allowed,
                )) |route| return route.streaming;
            }
            return false;
        }

        /// Methods supported somewhere in the router, used for `OPTIONS *`.
        pub fn allowedMethods(self: *@This()) AllowedMethods {
            var allowed = AllowedMethods{};
            for (self.all_routes.items) |route| {
                if (route.method) |method| {
                    allowed.add(method);
                } else {
                    inline for (.{
                        netz.http1.Method.GET,
                        netz.http1.Method.POST,
                        netz.http1.Method.PUT,
                        netz.http1.Method.DELETE,
                        netz.http1.Method.PATCH,
                        netz.http1.Method.HEAD,
                        netz.http1.Method.OPTIONS,
                    }) |method| allowed.add(method);
                }
            }
            return allowed;
        }

        /// Project the registered routes for `openapi.Document`. The returned
        /// views borrow route patterns and operation metadata; free the slice
        /// with the same allocator after building the document.
        pub fn openapiRoutes(
            self: *const @This(),
            allocator: std.mem.Allocator,
        ) ![]openapi_mod.RouteView {
            const views = try allocator.alloc(
                openapi_mod.RouteView,
                self.all_routes.items.len,
            );
            for (self.all_routes.items, 0..) |route, index| {
                views[index] = .{
                    .method = if (route.method) |method|
                        method.string()
                    else
                        null,
                    .pattern = route.pattern,
                    .operation = route.openapi,
                };
            }
            return views;
        }

        /// Match a method and path, returning null for both a missing path and
        /// a method mismatch. Use `resolve` when the distinction matters.
        pub fn match(
            self: *@This(),
            method: netz.http1.Method,
            path: []const u8,
            allocator: std.mem.Allocator,
        ) !?Match {
            return switch (try self.resolve(method, path, allocator)) {
                .matched => |matched| matched,
                else => null,
            };
        }

        fn matchNode(
            self: *@This(),
            node: *Node,
            source: []const u8,
            position: usize,
            depth: usize,
            method: netz.http1.Method,
            captures: *Captures,
            allowed: *AllowedMethods,
        ) ?*Route {
            if (depth > max_path_segments) return null;
            if (position >= source.len) {
                for (node.routes.items) |route| {
                    if (routeMatches(route.method, method)) return route;
                    if (route.method) |route_method| allowed.add(route_method);
                }
                for (node.wildcard_routes.items) |route| {
                    if (routeMatches(route.method, method)) {
                        if (captures.count >= max_params) return null;
                        captures.values[captures.count] = "";
                        captures.count += 1;
                        return route;
                    }
                    if (route.method) |route_method| allowed.add(route_method);
                }
                return null;
            }

            const end = std.mem.indexOfScalarPos(
                u8,
                source,
                position,
                '/',
            ) orelse source.len;
            const segment = source[position..end];
            const next_position = if (end < source.len) end + 1 else source.len;

            const static_child = if (node.single_child) |child|
                (if (std.mem.eql(u8, node.single_key.?, segment))
                    child
                else
                    null)
            else
                node.static_children.get(segment);
            if (static_child) |child| {
                if (self.matchNode(
                    child,
                    source,
                    next_position,
                    depth + 1,
                    method,
                    captures,
                    allowed,
                )) |route| return route;
            }

            if (segment.len > 0) {
                if (node.param) |child| {
                    if (captures.count >= max_params) return null;
                    captures.values[captures.count] = segment;
                    captures.count += 1;
                    if (self.matchNode(
                        child,
                        source,
                        next_position,
                        depth + 1,
                        method,
                        captures,
                        allowed,
                    )) |route| return route;
                    captures.count -= 1;
                }
            }

            for (node.wildcard_routes.items) |route| {
                if (routeMatches(route.method, method)) {
                    if (captures.count >= max_params) return null;
                    captures.values[captures.count] = source[position..];
                    captures.count += 1;
                    return route;
                }
                if (route.method) |route_method| allowed.add(route_method);
            }
            return null;
        }

        pub fn buildMatch(
            route: *const Route,
            captures: *const Captures,
            allocator: std.mem.Allocator,
            path: []const u8,
        ) !Match {
            if (route.capture_count == 0) {
                return .{ .route = route, .params = &.{}, .path = path };
            }
            const params = try allocator.alloc(Param, route.capture_count);
            for (route.capture_names, 0..) |name, index| {
                params[index] = .{
                    .name = name,
                    .value = captures.values[index],
                };
            }
            return .{
                .route = route,
                .params = params,
                .path = path,
            };
        }

        fn createNode(self: *@This()) !*Node {
            const node = try self.allocator.create(Node);
            node.* = .{};
            return node;
        }

        fn staticChild(
            self: *@This(),
            node: *Node,
            segment: []const u8,
        ) !*Node {
            if (node.single_child) |child| {
                if (std.mem.eql(u8, node.single_key.?, segment)) return child;
            } else if (node.static_children.get(segment)) |child| {
                return child;
            }

            const key = try self.allocator.dupe(u8, segment);
            errdefer self.allocator.free(key);
            const child = try self.createNode();
            errdefer self.allocator.destroy(child);

            if (node.single_child == null and
                node.static_children.count() == 0)
            {
                node.single_key = key;
                node.single_child = child;
                return child;
            }
            if (node.single_child) |existing| {
                // Promote the lone child into the map before adding another.
                try node.static_children.put(
                    self.allocator,
                    node.single_key.?,
                    existing,
                );
                node.single_key = null;
                node.single_child = null;
            }
            try node.static_children.put(self.allocator, key, child);
            return child;
        }

        /// Reject duplicate and shadowed registrations before mutating the
        /// trie, so a failed add leaves the router unchanged.
        fn checkConflict(
            self: *@This(),
            pattern: []const u8,
            method: ?netz.http1.Method,
        ) !void {
            const trimmed = std.mem.trim(u8, pattern, "/");
            var node: *Node = &self.root;
            var segments = SegmentIterator{ .source = trimmed };
            while (segments.next()) |segment| {
                if (std.mem.eql(u8, segment.text, "*")) {
                    try checkRoutesConflict(node.wildcard_routes.items, method);
                    return;
                }
                if (segment.text[0] == ':') {
                    node = node.param orelse return;
                } else if (node.single_child) |child| {
                    if (!std.mem.eql(
                        u8,
                        node.single_key.?,
                        segment.text,
                    )) return;
                    node = child;
                } else {
                    node = node.static_children.get(segment.text) orelse return;
                }
            }
            try checkRoutesConflict(node.routes.items, method);
        }

        fn deinitNode(self: *@This(), node: *Node) void {
            if (node.single_child) |child| {
                self.deinitNode(child);
                self.allocator.free(node.single_key.?);
            } else {
                var iterator = node.static_children.iterator();
                while (iterator.next()) |entry| {
                    self.deinitNode(entry.value_ptr.*);
                    self.allocator.free(entry.key_ptr.*);
                }
            }
            node.static_children.deinit(self.allocator);
            if (node.param) |child| self.deinitNode(child);
            node.routes.deinit(self.allocator);
            node.wildcard_routes.deinit(self.allocator);
            if (node != &self.root) self.allocator.destroy(node);
        }
    };
}

/// Count route entries reachable from a trie node. The allocation-failure
/// test uses it to assert that a failed registration leaves no route pointer
/// behind in the trie.
fn countTrieRoutes(node: *const Node) usize {
    var count = node.routes.items.len + node.wildcard_routes.items.len;
    if (node.single_child) |child| count += countTrieRoutes(child);
    var iterator = node.static_children.iterator();
    while (iterator.next()) |entry| count += countTrieRoutes(entry.value_ptr.*);
    if (node.param) |child| count += countTrieRoutes(child);
    return count;
}

fn checkRoutesConflict(
    routes: []const *Route,
    method: ?netz.http1.Method,
) !void {
    for (routes) |route| {
        const existing = route.method orelse return error.RouteConflict;
        const incoming = method orelse return error.RouteConflict;
        if (methodEqual(existing, incoming)) return error.DuplicateRoute;
    }
}

fn normalizeGroupPrefix(prefix: []const u8) ![]const u8 {
    if (prefix.len == 0) return "";
    if (prefix[0] != '/') return error.InvalidPattern;
    const trimmed = std.mem.trimEnd(u8, prefix, "/");
    if (trimmed.len == 0) return "";

    var segments = SegmentIterator{ .source = trimmed[1..] };
    while (segments.next()) |segment| {
        if (segment.text.len == 0) return error.InvalidPattern;
        for (segment.text) |char| {
            if (char == ':' or char == '*' or char == '?' or char == '#' or
                char < 0x20 or char == 0x7f)
            {
                return error.InvalidPattern;
            }
        }
    }
    return trimmed;
}

fn joinPath(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    suffix: []const u8,
) ![]u8 {
    if (suffix.len == 0) return allocator.dupe(u8, prefix);
    if (suffix[0] != '/') return error.InvalidPattern;
    if (std.mem.eql(u8, suffix, "/")) {
        return allocator.dupe(u8, if (prefix.len == 0) "/" else prefix);
    }
    if (prefix.len == 0) return allocator.dupe(u8, suffix);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, suffix });
}

fn concatHandlers(
    allocator: std.mem.Allocator,
    first: []const Handler,
    second: []const Handler,
) ![]const Handler {
    const total = first.len + second.len;
    const combined = try allocator.alloc(Handler, total);
    @memcpy(combined[0..first.len], first);
    @memcpy(combined[first.len..], second);
    return combined;
}

fn validatePattern(pattern: []const u8) !PatternInfo {
    if (pattern.len == 0 or pattern[0] != '/') return error.InvalidPattern;

    // Allow trailing slashes (`/users/` equals `/users`) but reject interior
    // or repeated empty segments, which would otherwise create ambiguous
    // matches.
    const trimmed = std.mem.trimEnd(u8, pattern[1..], "/");
    if (trimmed.len == 0) return .{ .captures = 0, .segments = 0 };

    var captures: usize = 0;
    var segments_count: usize = 0;
    var segments = SegmentIterator{ .source = trimmed };
    while (segments.next()) |segment| {
        segments_count += 1;
        if (segments_count > max_path_segments) return error.PatternTooDeep;
        if (segment.text.len == 0) return error.InvalidPattern;
        for (segment.text) |char| {
            if (char == '?' or char == '#' or char < 0x20 or char == 0x7f) {
                return error.InvalidPattern;
            }
        }
        if (segment.text[0] == ':') {
            if (segment.text.len == 1) return error.InvalidPattern;
            captures += 1;
        } else if (segment.text[0] == '*') {
            if (!std.mem.eql(u8, segment.text, "*")) return error.InvalidPattern;
            if (segments.next() != null) return error.InvalidPattern;
            captures += 1;
            break;
        }
        if (captures > max_params) return error.TooManyParams;
    }
    return .{ .captures = captures, .segments = segments_count };
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

fn routeMatches(
    route_method: ?netz.http1.Method,
    request_method: netz.http1.Method,
) bool {
    const method = route_method orelse return true;
    return methodEqual(method, request_method);
}

fn methodEqual(a: netz.http1.Method, b: netz.http1.Method) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .extension => |a_extension| switch (b) {
            .extension => |b_extension| std.mem.eql(u8, a_extension, b_extension),
            else => false,
        },
        else => true,
    };
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

test "leftmost static segment wins independent of registration order" {
    const allocator = std.testing.allocator;
    var router = Router(void).init(allocator);
    defer router.deinit();

    const Dummy = struct {
        fn handle(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    try router.addRaw(.GET, "/a/:b/c", ctx_mod.handler(Dummy.handle), .{});
    try router.addRaw(.GET, "/a/b/:c", ctx_mod.handler(Dummy.handle), .{});

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

    try router.addRaw(.GET, "/resource", ctx_mod.handler(Dummy.handle), .{});
    try router.addRaw(.POST, "/resource", ctx_mod.handler(Dummy.handle), .{});
    try router.addRaw(.DELETE, "/other", ctx_mod.handler(Dummy.handle), .{});

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

    try router.addRaw(.GET, "/users/:id", ctx_mod.handler(Dummy.handle), .{});
    try std.testing.expectError(
        error.DuplicateRoute,
        router.addRaw(.GET, "/users/:id", ctx_mod.handler(Dummy.handle), .{}),
    );
    try std.testing.expectError(
        error.RouteConflict,
        router.addRaw(null, "/users/:id", ctx_mod.handler(Dummy.handle), .{}),
    );
    try std.testing.expectError(
        error.InvalidPattern,
        router.addRaw(.GET, "/users/*/edit", ctx_mod.handler(Dummy.handle), .{}),
    );
    try std.testing.expectError(
        error.InvalidPattern,
        router.addRaw(.GET, "users", ctx_mod.handler(Dummy.handle), .{}),
    );
    try std.testing.expectError(
        error.InvalidPattern,
        router.addRaw(.GET, "//users", ctx_mod.handler(Dummy.handle), .{}),
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
        .middleware = &.{ctx_mod.handler(Dummy.middleware)},
    });
    try api.addRaw(.GET, "/users/:id", ctx_mod.handler(Dummy.handle), .{});

    var v1 = try api.group("/v1", .{
        .middleware = &.{ctx_mod.handler(Dummy.middleware)},
    });
    try v1.addRaw(.GET, "/health", ctx_mod.handler(Dummy.handle), .{});

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
        api.addRaw(.GET, "", ctx_mod.handler(Dummy.handle), .{}),
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
        try router.addRaw(.GET, pattern, ctx_mod.handler(Dummy.handle), .{});
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
                ctx_mod.handler(Dummy.handle),
                .{},
            ) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                // The route is freed by the error path, so the trie and the
                // ownership list must both be empty afterwards.
                try std.testing.expectEqual(
                    @as(usize, 0),
                    countTrieRoutes(&router.root),
                );
                try std.testing.expectEqual(
                    @as(usize, 0),
                    router.all_routes.items.len,
                );
                return err;
            };

            try std.testing.expectEqual(
                @as(usize, 1),
                countTrieRoutes(&router.root),
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
        const middleware = [_]Handler{ctx_mod.handler(Dummy.handle)};

        fn run(allocator: std.mem.Allocator) !void {
            var router = Router(void).init(allocator);
            defer router.deinit();

            router.addRaw(
                null,
                "/assets/*",
                ctx_mod.handler(Dummy.handle),
                .{ .middleware = &middleware },
            ) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(
                    @as(usize, 0),
                    countTrieRoutes(&router.root),
                );
                try std.testing.expectEqual(
                    @as(usize, 0),
                    router.all_routes.items.len,
                );
                return err;
            };

            try std.testing.expectEqual(
                @as(usize, 1),
                countTrieRoutes(&router.root),
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
        const middleware = [_]Handler{ctx_mod.handler(Dummy.handle)};

        fn run(allocator: std.mem.Allocator) !void {
            var router = Router(void).init(allocator);
            defer router.deinit();

            var api = try router.group("/api", .{ .middleware = &middleware });
            try api.addRaw(
                .GET,
                "/users/:id",
                ctx_mod.handler(Dummy.handle),
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
