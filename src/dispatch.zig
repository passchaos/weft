const std = @import("std");
const netz = @import("netz");
const logging_mod = @import("logging.zig");
const ctx_mod = @import("ctx.zig");
const errors_mod = @import("errors.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const query_mod = @import("query.zig");
const target_mod = @import("target.zig");

/// Why a request did not reach a route handler. Custom fallback handlers can
/// inspect this through `ctx.get(RouteFailure)`.
pub const RouteFailure = union(enum) {
    not_found,
    bad_request,
    method_not_allowed: router_mod.AllowedMethods,
    options_star: router_mod.AllowedMethods,
};

pub const Disposition = RouteFailure;

pub const Fallbacks = struct {
    not_found: ?ctx_mod.Handler = null,
    bad_request: ?ctx_mod.Handler = null,
    method_not_allowed: ?ctx_mod.Handler = null,
};

const HandlerRace = union(enum) {
    handler: void,
    timeout: void,
};

const HandlerRun = struct {
    context: *ctx_mod.Ctx,
    err: ?anyerror = null,
};

fn runHandler(run: *HandlerRun) void {
    run.context.run() catch |err| {
        run.err = err;
    };
}

fn sleepTask(io: std.Io, duration: std.Io.Duration) void {
    std.Io.sleep(io, duration, .awake) catch {};
}

/// Prepare a route lookup from a request target. Adapters call this before
/// reading the body; `dispatch` reuses the result so the trie is walked once
/// per request.
pub fn prepareRoute(
    comptime H: type,
    router: *router_mod.Router(H),
    method: netz.http1.Method,
    target: []const u8,
    out: *router_mod.Prepared,
) void {
    out.route = null;
    out.allowed.len = 0;
    out.captures.count = 0;
    const path = target_mod.split(target).path;
    if (method == .OPTIONS and std.mem.eql(u8, path, "*")) return;
    router.prepare(method, path, out);
}

/// Dispatch one parsed request through the application router and middleware.
///
/// The request is an HTTP/1 shape even for non-HTTP/1 adapters; adapters map
/// their native request into this concrete view before calling.
pub fn dispatch(
    comptime H: type,
    app: *H,
    router: *router_mod.Router(H),
    io: std.Io,
    limits: limits_mod.Limits,
    app_middleware: []const ctx_mod.Handler,
    fallbacks: Fallbacks,
    request: *const netz.http1.Request,
    client_info: ctx_mod.ClientInfo,
    arena: std.mem.Allocator,
    request_allocator: std.mem.Allocator,
    body_reader: ?ctx_mod.BodyReader,
    prepared: *const router_mod.Prepared,
) !response_mod.Response {
    const target = request.target;
    const split_target = target_mod.split(target);
    const path = split_target.path;
    const query = split_target.query;

    var disposition: ?Disposition = null;
    var matched_route: ?*const router_mod.Route = null;
    if (request.method == .OPTIONS and
        std.mem.eql(u8, path, "*"))
    {
        disposition = .{ .options_star = router.allowedMethods() };
    } else if (prepared.route) |route| {
        matched_route = route;
    } else if (prepared.allowed.len > 0) {
        disposition = .{ .method_not_allowed = prepared.allowed };
    } else {
        disposition = .not_found;
    }
    var query_params: []const query_mod.Pair = &.{};
    var params: []const ctx_mod.Param = &.{};
    var params_storage: [ctx_mod.max_params]ctx_mod.Param = undefined;
    var route_middleware: []const ctx_mod.Handler = &.{};
    var route_max_body: ?usize = null;
    var route_timeout: ?std.Io.Duration = null;
    var final_handler: ctx_mod.Handler = ctx_mod.handler(respondDisposition);

    const parsed_query = query_mod.parse(
        arena,
        query,
        limits.max_query_params,
    ) catch blk: {
        disposition = .bad_request;
        break :blk query_mod.Query{};
    };
    query_params = parsed_query.pairs;

    if (matched_route) |route| {
        if (disposition == null) {
            if (decodeParams(
                arena,
                route,
                &prepared.captures.values,
                &params_storage,
            ) catch null) |decoded| {
                params = decoded;
                route_middleware = route.middleware;
                route_max_body = route.max_body_bytes;
                route_timeout = route.timeout;
                final_handler = route.handler;
            } else {
                disposition = .bad_request;
            }
        }
    }

    if (disposition) |value| {
        final_handler = fallbackHandler(fallbacks, value);
    }

    var effective_limits = limits;
    if (route_max_body) |route_limit| {
        effective_limits.max_body_bytes = route_limit;
        if (disposition == null and request.body.len > route_limit) {
            // A buffered body was already read under the server-wide limit;
            // reject it before any handler sees it.
            disposition = .bad_request;
            final_handler = ctx_mod.handler(respondPayloadTooLarge);
        }
    }

    var limited_reader: ctx_mod.LimitedReader = undefined;
    var effective_reader = body_reader;
    if (effective_reader) |reader| {
        // HTTP/1's pull reader enforces the server-wide budget itself, but
        // Netz's HTTP/2 concurrent stream and HTTP/3 stream readers do not.
        // Apply the effective budget here for every adapter, including
        // fallback handlers, so a handler cannot read past it. The wrapper
        // lives on this stack frame, which outlives the handler chain.
        limited_reader = .{
            .inner = reader,
            .remaining = effective_limits.max_body_bytes,
        };
        effective_reader = .{ .limited = &limited_reader };
    }

    if (disposition == null and
        app_middleware.len + route_middleware.len > limits.max_middleware)
    {
        return error.TooMuchMiddleware;
    }

    const effective_timeout = route_timeout orelse limits.request_timeout;
    const request_deadline = if (effective_timeout) |duration|
        std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = duration,
            .clock = .awake,
        })
    else
        null;

    var context = ctx_mod.Ctx{
        .app = @ptrCast(app),
        .io = io,
        .arena = arena,
        .request_allocator = request_allocator,
        .limits = effective_limits,
        .request = request,
        .body_reader = effective_reader,
        .client_info = client_info,
        .request_deadline = request_deadline,
        .query = query,
        .query_params = query_params,
        .params = params,
        .response = response_mod.Response.initWithLimits(
            arena,
            effective_limits,
        ),
        .middleware = app_middleware,
        .route_middleware = if (disposition == null)
            route_middleware
        else
            &.{},
        .final_handler = final_handler,
    };
    context.response.staging_allocator = request_allocator;

    if (disposition) |value| {
        try context.set(RouteFailure, value);
        switch (value) {
            .not_found => context.response.setStatus(404),
            .bad_request => context.response.setStatus(400),
            .method_not_allowed => |allowed| {
                context.response.setStatus(405);
                try context.response.setHeader(
                    "Allow",
                    try allowed.value(arena),
                );
            },
            .options_star => |allowed| {
                context.response.setStatus(204);
                try context.response.setHeader(
                    "Allow",
                    try allowed.value(arena),
                );
            },
        }
    }

    if (effective_timeout) |duration| {
        var run = HandlerRun{ .context = &context };
        var race_buffer: [2]HandlerRace = undefined;
        var select = std.Io.Select(HandlerRace).init(io, &race_buffer);
        defer select.cancelDiscard();

        try select.concurrent(.handler, runHandler, .{&run});
        try select.concurrent(.timeout, sleepTask, .{ io, duration });

        const winner = select.await() catch |err| return err;
        switch (winner) {
            .handler => if (run.err) |err| {
                if (err == error.Canceled) return error.Canceled;
                applyHandlerError(&context, err);
            },
            .timeout => {
                // The handler task may still be mutating the response; wait
                // for cancellation before replacing it.
                select.cancelDiscard();
                context.response.reset();
                context.response.setStatus(503);
                context.response.text("Service Unavailable") catch {};
            },
        }
    } else {
        context.run() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            applyHandlerError(&context, err);
        };
    }

    return context.response;
}

fn fallbackHandler(
    fallbacks: Fallbacks,
    failure: RouteFailure,
) ctx_mod.Handler {
    return switch (failure) {
        .not_found => fallbacks.not_found orelse
            ctx_mod.handler(respondDisposition),
        .bad_request => fallbacks.bad_request orelse
            ctx_mod.handler(respondDisposition),
        .method_not_allowed => fallbacks.method_not_allowed orelse
            ctx_mod.handler(respondDisposition),
        .options_star => ctx_mod.handler(respondDisposition),
    };
}

fn respondPayloadTooLarge(ctx: *ctx_mod.Ctx) anyerror!void {
    ctx.setStatus(413);
    try ctx.text("Payload Too Large");
}

fn respondDisposition(ctx: *ctx_mod.Ctx) anyerror!void {
    const disposition = ctx.get(Disposition) orelse {
        ctx.setStatus(500);
        return ctx.text("Internal Server Error");
    };

    switch (disposition) {
        .not_found => {
            ctx.setStatus(404);
            try ctx.text("Not Found");
        },
        .bad_request => {
            ctx.setStatus(400);
            try ctx.text("Bad Request");
        },
        .method_not_allowed => |allowed| {
            try ctx.setHeader("Allow", try allowed.value(ctx.arena));
            if (ctx.method() == .OPTIONS) {
                ctx.setStatus(204);
                return;
            }
            ctx.setStatus(405);
            try ctx.text("Method Not Allowed");
        },
        .options_star => |allowed| {
            try ctx.setHeader("Allow", try allowed.value(ctx.arena));
            ctx.setStatus(204);
        },
    }
}

fn decodeParams(
    arena: std.mem.Allocator,
    route: *const router_mod.Route,
    capture_values: []const []const u8,
    storage: *[ctx_mod.max_params]ctx_mod.Param,
) ![]const ctx_mod.Param {
    const count = route.capture_names.len;
    if (count == 0) return &.{};
    if (count > storage.len or capture_values.len < count) {
        return error.InvalidRoute;
    }
    for (route.capture_names, 0..) |name, index| {
        storage[index] = .{
            .name = name,
            .value = try query_mod.decodeComponentBorrowed(
                arena,
                capture_values[index],
                false,
            ),
        };
    }
    return storage[0..count];
}

fn applyHandlerError(context: *ctx_mod.Ctx, err: anyerror) void {
    // Nothing has reached the wire yet, so a failed handler can always be
    // replaced with a clean response.
    const status = errors_mod.statusForHandlerError(err);
    // Client errors such as a per-route body budget are expected outcomes;
    // only server-side failures deserve a warning.
    if (status >= 500) {
        logging_mod.logWarn(
            "weft",
            "handler failed: {s}",
            .{@errorName(err)},
            .{ .err = @errorName(err) },
        );
    } else {
        logging_mod.logDebug(
            "weft",
            "handler rejected: {s}",
            .{@errorName(err)},
            .{ .err = @errorName(err) },
        );
    }
    context.response.reset();
    context.response.setStatus(status);
    context.response.text(response_mod.reasonFor(status)) catch {};
}

test "fallback handlers keep the streaming body bounded" {
    var app: void = {};
    var router = router_mod.Router(void).init(std.testing.allocator);
    defer router.deinit();

    var replay = ctx_mod.ReplayReader{ .body = "0123456789abcdef" };
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/missing",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var prepared: router_mod.Prepared = .{};
    const drainBody = struct {
        fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
            var total: usize = 0;
            while (try ctx.bodyReader().?.next()) |chunk| total += chunk.len;
            ctx.setStatus(200);
            try ctx.text("drained");
        }
    }.handle;

    const response = try dispatch(
        void,
        &app,
        &router,
        std.testing.io,
        .{
            .max_body_bytes = 4,
            .max_response_bytes = 1024,
        },
        &.{},
        .{ .not_found = ctx_mod.handler(drainBody) },
        &request,
        .{},
        arena.allocator(),
        std.testing.allocator,
        .{ .replay = &replay },
        &prepared,
    );
    try std.testing.expectEqual(@as(u16, 413), response.status);
}
