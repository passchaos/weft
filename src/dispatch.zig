const std = @import("std");
const netz = @import("netz");
const ctx_mod = @import("ctx.zig");
const router_mod = @import("router.zig");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const query_mod = @import("query.zig");

pub const Disposition = union(enum) {
    not_found,
    bad_request,
    method_not_allowed: router_mod.AllowedMethods,
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
    request: *const netz.http1.Request,
    client_info: ctx_mod.ClientInfo,
    arena: std.mem.Allocator,
) !response_mod.Response {
    const target = request.target;
    const query_index = std.mem.indexOfScalar(u8, target, '?');
    const path = if (query_index) |index| target[0..index] else target;
    const query = if (query_index) |index| target[index + 1 ..] else "";

    const resolution = try router.resolve(request.method, path, arena);

    var disposition: ?Disposition = null;
    var query_params: []const query_mod.Pair = &.{};
    var params: []const ctx_mod.Param = &.{};
    var route_middleware: []const ctx_mod.Handler = &.{};
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

    var context = ctx_mod.Ctx{
        .app = @ptrCast(app),
        .io = io,
        .arena = arena,
        .limits = limits,
        .request = request,
        .client_info = client_info,
        .query = query,
        .query_params = query_params,
        .params = params,
        .response = response_mod.Response.initWithLimits(arena, limits),
        .middleware = middleware,
        .final_handler = final_handler,
    };

    if (disposition) |value| {
        try context.set(Disposition, value);
    }

    if (limits.request_timeout) |duration| {
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
    std.log.scoped(.weft).warn(
        "handler failed: {s}",
        .{@errorName(err)},
    );
    // Nothing has reached the wire yet, so a failed handler can always be
    // replaced with a clean response.
    const status = statusForHandlerError(err);
    context.response.reset();
    context.response.setStatus(status);
    context.response.text(response_mod.reasonFor(status)) catch {};
}

fn statusForHandlerError(err: anyerror) u16 {
    if (err == error.UnsupportedMediaType or err == error.NotMultipart) return 415;
    if (err == error.PayloadTooLarge) return 413;
    if (err == error.BadRequest or
        err == error.InvalidJson or
        err == error.MissingBoundary or
        err == error.InvalidMultipart or
        err == error.TooManyParts)
    {
        return 400;
    }
    return 500;
}
