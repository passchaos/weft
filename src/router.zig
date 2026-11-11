const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const handler_mod = @import("handler.zig");
const openapi_mod = @import("openapi.zig");
const trie = @import("router/trie.zig");

const Ctx = ctx_mod.Ctx;
const Handler = handler_mod.Handler;
const Param = handler_mod.Param;
const max_params = handler_mod.max_params;

/// Maximum number of path segments accepted by the matcher.
pub const max_path_segments = trie.max_path_segments;

/// Maximum methods stored in one `Allow` field.
pub const max_allowed_methods = 16;

pub const RouteOptions = struct {
    /// Optional unique route name for `Router.urlFor`.
    name: ?[]const u8 = null,
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
    /// Allow the HTTP/2 engine to run this route's handler on the connection
    /// owner for already-complete (bodyless) requests. Inline handlers must
    /// produce a buffered response: `ctx.stream`, `ctx.sse`, and WebSocket
    /// upgrades are rejected. Leave false for handlers that may block.
    inline_bodyless: bool = false,
};

pub const GroupOptions = struct {
    /// Middleware runs before every route registered through the group.
    middleware: []const Handler = &.{},
};

pub const Route = struct {
    /// Optional unique route name for reverse URL generation.
    name: ?[]const u8 = null,
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
    /// True when the HTTP/2 engine may run this route inline.
    inline_bodyless: bool = false,
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

const Node = trie.Node;
const SegmentIterator = trie.SegmentIterator;
const Captures = trie.Captures;

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
                        .name = route_options.name,
                        .middleware = combined_middleware,
                        .streaming = route_options.streaming,
                        .max_body_bytes = route_options.max_body_bytes,
                        .timeout = route_options.timeout,
                        .openapi = route_options.openapi,
                        .inline_bodyless = route_options.inline_bodyless,
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
                    handler_mod.handlerFor(H, f),
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
                    handler_mod.handlerFor(H, f),
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
                    handler_mod.handlerFor(H, f),
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
                    handler_mod.handlerFor(H, f),
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
                    handler_mod.handlerFor(H, f),
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
                    handler_mod.handlerFor(H, f),
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
                    handler_mod.handlerFor(H, f),
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
                    handler_mod.handlerFor(H, f),
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
                if (route.name) |name| self.allocator.free(name);
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
            if (route_options.name) |name| {
                if (name.len == 0) return error.InvalidRouteName;
                for (self.all_routes.items) |existing| {
                    if (existing.name) |existing_name| {
                        if (std.mem.eql(u8, existing_name, name)) {
                            return error.DuplicateRouteName;
                        }
                    }
                }
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
            const name_copy: ?[]const u8 = if (route_options.name) |name|
                try self.allocator.dupe(u8, name)
            else
                null;
            errdefer if (name_copy) |name| self.allocator.free(name);

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
                .name = name_copy,
                .method = method,
                .pattern = pattern_copy,
                .handler = handler,
                .middleware = middleware_copy,
                .streaming = route_options.streaming,
                .max_body_bytes = route_options.max_body_bytes,
                .timeout = route_options.timeout,
                .openapi = route_options.openapi,
                .inline_bodyless = route_options.inline_bodyless,
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

        /// Copy every route from `other` into this router.
        pub fn merge(self: *@This(), other: *Self) !void {
            for (other.all_routes.items) |route| {
                try self.addRaw(route.method, route.pattern, route.handler, .{
                    .name = route.name,
                    .middleware = route.middleware,
                    .streaming = route.streaming,
                    .max_body_bytes = route.max_body_bytes,
                    .timeout = route.timeout,
                    .openapi = route.openapi,
                    .inline_bodyless = route.inline_bodyless,
                });
            }
        }

        /// Mount every route from `other` under `prefix`.
        pub fn nest(
            self: *@This(),
            prefix: []const u8,
            other: *Self,
        ) !void {
            var nested_group = try self.group(prefix, .{});
            for (other.all_routes.items) |route| {
                try nested_group.addRaw(route.method, route.pattern, route.handler, .{
                    .name = route.name,
                    .middleware = route.middleware,
                    .streaming = route.streaming,
                    .max_body_bytes = route.max_body_bytes,
                    .timeout = route.timeout,
                    .openapi = route.openapi,
                    .inline_bodyless = route.inline_bodyless,
                });
            }
        }

        /// Build a path for a named route. `:param` values are percent-encoded;
        /// a trailing `*` value is inserted verbatim so it can span segments.
        pub fn urlFor(
            self: *const Self,
            allocator: std.mem.Allocator,
            name: []const u8,
            params: []const Param,
        ) ![]const u8 {
            var route: ?*const Route = null;
            for (self.all_routes.items) |candidate| {
                if (candidate.name) |candidate_name| {
                    if (std.mem.eql(u8, candidate_name, name)) {
                        route = candidate;
                        break;
                    }
                }
            }
            const matched = route orelse return error.UnknownRoute;
            var writer = std.Io.Writer.Allocating.init(allocator);
            errdefer writer.deinit();
            try writer.writer.writeByte('/');
            var segments = SegmentIterator{
                .source = std.mem.trim(u8, matched.pattern, "/"),
            };
            var first = true;
            while (segments.next()) |segment| {
                if (!first) try writer.writer.writeByte('/');
                first = false;
                if (segment.text.len != 0 and segment.text[0] == ':') {
                    const value = findParam(params, segment.text[1..]) orelse
                        return error.MissingParam;
                    try std.Uri.Component.percentEncode(
                        &writer.writer,
                        value,
                        pathComponentChar,
                    );
                } else if (std.mem.eql(u8, segment.text, "*")) {
                    const value = findParam(params, "*") orelse
                        return error.MissingParam;
                    try writer.writer.writeAll(value);
                } else {
                    try writer.writer.writeAll(segment.text);
                }
            }
            if (matched.pattern.len > 1 and
                matched.pattern[matched.pattern.len - 1] == '/')
            {
                try writer.writer.writeByte('/');
            }
            return writer.toOwnedSlice();
        }

        pub fn get(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.GET, pattern, handler_mod.handlerFor(H, f), route_options);
        }

        pub fn post(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.POST, pattern, handler_mod.handlerFor(H, f), route_options);
        }

        pub fn put(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.PUT, pattern, handler_mod.handlerFor(H, f), route_options);
        }

        pub fn delete(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.DELETE, pattern, handler_mod.handlerFor(H, f), route_options);
        }

        pub fn patch(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.PATCH, pattern, handler_mod.handlerFor(H, f), route_options);
        }

        pub fn head(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.HEAD, pattern, handler_mod.handlerFor(H, f), route_options);
        }

        pub fn options(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(.OPTIONS, pattern, handler_mod.handlerFor(H, f), route_options);
        }

        /// Register a route for every HTTP method.
        pub fn any(
            self: *@This(),
            pattern: []const u8,
            comptime f: fn (*H, *Ctx) anyerror!void,
            route_options: RouteOptions,
        ) !void {
            return self.addRaw(null, pattern, handler_mod.handlerFor(H, f), route_options);
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

        /// Whether any route opted into the HTTP/2 inline bodyless path.
        pub fn hasInlineBodylessRoutes(self: *const @This()) bool {
            for (self.all_routes.items) |route| {
                if (route.inline_bodyless) return true;
            }
            return false;
        }

        /// Number of route entries reachable from the trie. Used by tests that
        /// assert a failed registration leaves no route pointer behind.
        pub fn debugRouteCount(self: *const @This()) usize {
            return countTrieRoutes(&self.root);
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

fn findParam(params: []const Param, name: []const u8) ?[]const u8 {
    for (params) |param| {
        if (std.mem.eql(u8, param.name, name)) return param.value;
    }
    return null;
}

fn pathComponentChar(char: u8) bool {
    return switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
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

const validatePattern = trie.validatePattern;
const computeSpecificity = trie.computeSpecificity;
const routeMatches = trie.routeMatches;
const methodEqual = trie.methodEqual;
