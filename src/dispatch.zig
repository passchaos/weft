const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const errors_mod = @import("errors.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const query_mod = @import("query.zig");

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
) !response_mod.Response {
    const target = request.target;
    const query_index = std.mem.indexOfScalar(u8, target, '?');
    const path = if (query_index) |index| target[0..index] else target;
    const query = if (query_index) |index| target[index + 1 ..] else "";

    var disposition: ?Disposition = null;
    const resolution = if (request.method == .OPTIONS and
        std.mem.eql(u8, target, "*"))
    blk: {
        disposition = .{ .options_star = router.allowedMethods() };
        break :blk router_mod.Resolution.not_found;
    } else try router.resolve(request.method, path, arena);
    var query_params: []const query_mod.Pair = &.{};
    var params: []const ctx_mod.Param = &.{};
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

    switch (resolution) {
        .matched => |matched| {
            if (disposition == null) {
                if (decodeParams(arena, matched.params) catch null) |decoded| {
                    params = decoded;
                    route_middleware = matched.route.middleware;
                    route_max_body = matched.route.max_body_bytes;
                    route_timeout = matched.route.timeout;
                    final_handler = matched.route.handler;
                } else {
                    disposition = .bad_request;
                }
            }
        },
        .method_not_allowed => |allowed| {
            if (disposition == null) {
                disposition = .{ .method_not_allowed = allowed };
            }
        },
        .not_found => {
            if (disposition == null) disposition = .not_found;
        },
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

    var effective_reader = body_reader;
    if (disposition == null) {
        if (effective_reader) |reader| {
            if (effective_limits.max_body_bytes < limits.max_body_bytes) {
                const limited = try arena.create(ctx_mod.LimitedReader);
                limited.* = .{
                    .inner = reader,
                    .remaining = effective_limits.max_body_bytes,
                };
                effective_reader = .{ .limited = limited };
            }
        }
    }

    var middleware = app_middleware;
    if (disposition == null and route_middleware.len > 0) {
        const total = middleware.len + route_middleware.len;
        if (total > limits.max_middleware) {
            return error.TooMuchMiddleware;
        }
        const combined = try arena.alloc(ctx_mod.Handler, total);
        @memcpy(combined[0..middleware.len], middleware);
        @memcpy(combined[middleware.len..], route_middleware);
        middleware = combined;
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
        .middleware = middleware,
        .final_handler = final_handler,
    };

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
    raw: []const ctx_mod.Param,
) ![]const ctx_mod.Param {
    if (raw.len == 0) return &.{};
    const decoded = try arena.alloc(ctx_mod.Param, raw.len);
    for (raw, 0..) |param, index| {
        decoded[index] = .{
            .name = param.name,
            .value = try query_mod.decodeComponent(arena, param.value, false),
        };
    }
    return decoded;
}

fn applyHandlerError(context: *ctx_mod.Ctx, err: anyerror) void {
    // Nothing has reached the wire yet, so a failed handler can always be
    // replaced with a clean response.
    const status = errors_mod.statusForHandlerError(err);
    // Client errors such as a per-route body budget are expected outcomes;
    // only server-side failures deserve a warning.
    if (status >= 500) {
        std.log.scoped(.weft).warn(
            "handler failed: {s}",
            .{@errorName(err)},
        );
    } else {
        std.log.scoped(.weft).debug(
            "handler rejected: {s}",
            .{@errorName(err)},
        );
    }
    context.response.reset();
    context.response.setStatus(status);
    context.response.text(response_mod.reasonFor(status)) catch {};
}
