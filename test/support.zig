const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;

pub const App = struct {};

pub fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("hello from weft");
}

pub fn upload(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const form = try ctx.multipart();
    const field = form.part("field") orelse {
        ctx.setStatus(400);
        return ctx.text("Missing field");
    };
    const file = form.part("file") orelse {
        ctx.setStatus(400);
        return ctx.text("Missing file");
    };
    try ctx.json(.{
        .field = field.data,
        .filename = file.filename orelse "",
        .size = file.data.len,
    });
}

pub fn websocketEcho(
    _: ?*anyopaque,
    session: *weft.WebSocketSession,
) anyerror!void {
    var message = try session.receiveMessage();
    defer session.deinitMessage(&message);
    try session.sendText(message.payload);
}

pub fn websocketRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.upgradeWebSocket(.{ .run_fn = websocketEcho });
}

pub fn websocketCompressedRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.upgradeWebSocket(.{
        .run_fn = websocketEcho,
        .compression = true,
    });
}

pub fn clientAddressText(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const address = ctx.clientAddress() orelse return ctx.text("none");
    try ctx.text(try std.fmt.allocPrint(ctx.arena, "{f}", .{address}));
}

pub fn deadlineInfo(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.json(.{
        .has_deadline = ctx.deadline() != null,
        .expired = ctx.expired(),
    });
}

pub fn customNotFound(ctx: *weft.Ctx) anyerror!void {
    const failure = ctx.get(weft.RouteFailure) orelse
        return ctx.internalError();
    const kind = switch (failure) {
        .not_found => "not_found",
        else => "other",
    };
    try ctx.json(.{ .custom = kind, .status = ctx.response.status });
}

pub fn customMethodNotAllowed(ctx: *weft.Ctx) anyerror!void {
    const failure = ctx.get(weft.RouteFailure) orelse
        return ctx.internalError();
    const allow = switch (failure) {
        .method_not_allowed => |allowed| allowed,
        else => return ctx.internalError(),
    };
    try ctx.json(.{
        .custom = "method_not_allowed",
        .allow = try allow.value(ctx.arena),
    });
}

pub fn clientInfo(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.json(.{
        .protocol = @tagName(ctx.protocol()),
        .has_address = ctx.clientAddress() != null,
        .tls = ctx.isTls(),
    });
}

pub fn cookiesRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.setCookie(.{
        .name = "session",
        .value = "abc",
        .path = "/",
        .http_only = true,
        .same_site = .lax,
    });
    try ctx.setCookie(.{
        .name = "__Host-theme",
        .value = "dark",
        .path = "/",
        .secure = true,
    });
    try ctx.text("ok");
}

pub fn certificateCount(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.json(.{ .certs = ctx.peerCertificates().len });
}

pub fn etagRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("hello");
}

pub fn trailerRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("body");
    try ctx.addTrailer("X-Checksum", "abc");
}
pub fn trailerBody(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
    try writer.write("body");
}

pub fn bufferedTrailerEcho(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text(ctx.trailer("x-checksum") orelse "");
}

pub fn streamingTrailerEcho(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const reader = ctx.bodyReader().?;
    while (try reader.next()) |_| {}
    try ctx.text(ctx.trailer("x-checksum") orelse "");
}

pub fn streamingTrailerRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.addTrailer("X-Checksum", "abc");
    try ctx.stream(.{ .write_fn = trailerBody, .length = 4 });
}

pub fn hello(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const name = ctx.param("name") orelse "stranger";
    try ctx.json(.{
        .message = "hello",
        .name = name,
    });
}

pub const JsonPayload = struct {
    message: []const u8,
};

pub fn echoJson(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const payload = try ctx.bodyJson(JsonPayload);
    try ctx.json(.{ .message = payload.message });
}

pub fn echoBufferedBody(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text(ctx.body());
}

pub fn gzipAlloc(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    defer output.deinit();

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var encoder = try std.compress.flate.Compress.init(
        &output.writer,
        &window,
        .gzip,
        .default,
    );
    try encoder.writer.writeAll(body);
    try encoder.finish();
    return output.toOwnedSlice();
}

pub fn serveHttp2Server(
    server: *weft.Http2Server(App),
) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn("http2 server failed: {s}", .{@errorName(err)});
            return;
        },
    };
}

pub fn serveHttp3Server(
    server: *weft.Http3Server(App),
) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn("http3 server failed: {s}", .{@errorName(err)});
            return;
        },
    };
}

pub fn h2Header(
    response: *const netz.http2.runtime.OwnedResponse,
    name: []const u8,
) ?[]const u8 {
    for (response.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

pub fn h3Header(
    response: *const netz.http3.runtime.OwnedHandshakeResponse,
    name: []const u8,
) ?[]const u8 {
    for (response.response.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

pub fn serveServer(server: *weft.Server(App)) std.Io.Cancelable!void {
    server.serve() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.scoped(.weft).warn("server failed: {s}", .{@errorName(err)});
            return;
        },
    };
}

pub fn slowHandler(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try std.Io.sleep(ctx.io, .fromMilliseconds(200), .awake);
    try ctx.text("slow");
}

pub const StreamHandlers = struct {
    pub fn fixed(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
        try writer.write("hello ");
        try writer.write("stream");
    }

    pub fn chunked(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
        try writer.write("chunked ");
        try writer.write("body");
    }

    pub fn fixedRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.setHeader("Content-Type", "text/plain; charset=utf-8");
        try ctx.stream(.{ .write_fn = fixed, .length = 12 });
    }

    pub fn chunkedRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.setHeader("Content-Type", "text/plain; charset=utf-8");
        try ctx.stream(.{ .write_fn = chunked });
    }

    pub fn oversizedRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.stream(.{ .write_fn = fixed, .length = 512 });
    }

    pub fn sse(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
        try weft.sse.write(writer, .{
            .id = "1",
            .event = "tick",
            .data = "first\nsecond",
        });
        try weft.sse.comment(writer, "keep-alive");
    }

    pub fn sseRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.sse(.{ .write_fn = sse });
    }

    pub fn uploadRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        const reader = ctx.bodyReader().?;
        var total: usize = 0;
        while (try reader.next()) |chunk| total += chunk.len;
        try ctx.json(.{ .bytes = total });
    }

    pub fn decodedUploadRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        const reader = if (try ctx.decodedReader()) |decoded|
            weft.BodyReader{ .decoded = decoded }
        else
            ctx.bodyReader().?;
        var total: usize = 0;
        while (try reader.next()) |chunk| total += chunk.len;
        try ctx.json(.{ .bytes = total });
    }

    pub fn multipartStreamRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        var stream = try ctx.multipartStream();
        defer stream.deinit();
        var field: []const u8 = "";
        var file_bytes: usize = 0;
        while (try stream.nextPart()) |part| {
            var total: usize = 0;
            while (try part.data.next()) |chunk| total += chunk.len;
            if (std.mem.eql(u8, part.name, "field")) {
                field = try ctx.arena.dupe(u8, part.name);
            } else if (std.mem.eql(u8, part.name, "file")) {
                file_bytes = total;
            }
        }
        try ctx.json(.{ .field = field, .file_bytes = file_bytes });
    }

    pub fn readBodyRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        const body = try ctx.readBody();
        try ctx.json(.{ .bytes = body.len });
    }

    /// Reports whether the adapter exposed the incremental reader, without
    /// dereferencing it. Streaming-route detection must ignore the query.
    pub fn streamingProbeRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        try ctx.json(.{ .streaming = ctx.bodyReader() != null });
    }

    pub fn rejectUpload(app: *App, ctx: *weft.Ctx) anyerror!void {
        _ = app;
        ctx.setStatus(413);
        try ctx.text("too large");
    }
};

pub const MethodHandlers = struct {
    pub fn resource(ctx: *weft.Ctx) anyerror!void {
        try ctx.text("resource");
    }

    pub fn echo(ctx: *weft.Ctx) anyerror!void {
        try ctx.json(.{
            .name = ctx.param("name") orelse "",
            .q = ctx.queryParam("q") orelse "",
        });
    }

    pub fn tooManyHeaders(ctx: *weft.Ctx) anyerror!void {
        try ctx.setHeader("X-A", "a");
        try ctx.setHeader("X-B", "b");
        try ctx.setHeader("X-C", "c");
        try ctx.text("ok");
    }
};

pub const OrderState = struct {
    pub fn append(ctx: *weft.Ctx, suffix: []const u8) !void {
        const existing = ctx.responseHeader("x-order") orelse "";
        try ctx.setHeader(
            "X-Order",
            try std.fmt.allocPrint(
                ctx.arena,
                "{s}{s}",
                .{ existing, suffix },
            ),
        );
    }

    pub fn app(ctx: *weft.Ctx) anyerror!void {
        try append(ctx, "a");
        try ctx.next();
    }

    pub fn route(ctx: *weft.Ctx) anyerror!void {
        try append(ctx, "r");
        try ctx.next();
    }

    pub fn finalRoute(_: *App, ctx: *weft.Ctx) anyerror!void {
        try append(ctx, "h");
        try ctx.text("ok");
    }
};

pub fn mcpEchoTool(tool_ctx: *weft.mcp.ToolContext) anyerror!void {
    const message = tool_ctx.stringArgument("message") orelse "";
    try tool_ctx.text(message);
}
