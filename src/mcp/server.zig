const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const types = @import("types.zig");
const stream_mod = @import("../stream.zig");
const sse_mod = @import("../sse.zig");

const Role = types.Role;
const ToolAnnotations = types.ToolAnnotations;
const ToolContext = types.ToolContext;
const ToolHandler = types.ToolHandler;
const Tool = types.Tool;
const Resource = types.Resource;
const PromptArgument = types.PromptArgument;
const PromptMessage = types.PromptMessage;
const Prompt = types.Prompt;
const Options = types.Options;
const Handler = handler_mod.Handler;

const session_id_len = 32;

const Session = struct {
    id: [session_id_len]u8,
    last_seen: std.Io.Clock.Timestamp,
    events: std.ArrayListUnmanaged([]u8) = .empty,
};

const SseContext = struct {
    server: *Server,
    session_id: [session_id_len]u8,
    io: std.Io,
    poll_interval: std.Io.Duration,
    keep_alive_interval: std.Io.Duration,
    idle_timeout: std.Io.Duration,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    options: Options,
    tools: std.ArrayListUnmanaged(Tool) = .empty,
    resources: std.ArrayListUnmanaged(Resource) = .empty,
    prompts: std.ArrayListUnmanaged(Prompt) = .empty,
    sessions: std.AutoHashMapUnmanaged([session_id_len]u8, *Session) = .empty,
    session_mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, options: Options) Server {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: *Server) void {
        self.tools.deinit(self.allocator);
        self.resources.deinit(self.allocator);
        self.prompts.deinit(self.allocator);
        self.lockSession();
        var session_iterator = self.sessions.iterator();
        while (session_iterator.next()) |entry| {
            self.destroySessionLocked(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
        self.unlockSession();
        self.* = undefined;
    }

    pub fn addTool(self: *Server, tool: Tool) !void {
        if (tool.name.len == 0) return error.InvalidToolName;
        if (self.tools.items.len >= self.options.max_tools) {
            return error.TooManyTools;
        }
        for (self.tools.items) |existing| {
            if (std.mem.eql(u8, existing.name, tool.name)) {
                return error.DuplicateTool;
            }
        }
        try validateJsonObject(self.allocator, tool.input_schema_json);
        if (tool.output_schema_json) |schema| {
            try validateJsonObject(self.allocator, schema);
        }
        try self.tools.append(self.allocator, tool);
    }

    pub fn addResource(self: *Server, resource: Resource) !void {
        if (resource.uri.len == 0 or resource.name.len == 0) {
            return error.InvalidResource;
        }
        if (self.resources.items.len >= self.options.max_resources) {
            return error.TooManyResources;
        }
        for (self.resources.items) |existing| {
            if (std.mem.eql(u8, existing.uri, resource.uri)) {
                return error.DuplicateResource;
            }
        }
        try self.resources.append(self.allocator, resource);
    }

    pub fn addPrompt(self: *Server, prompt: Prompt) !void {
        if (prompt.name.len == 0) return error.InvalidPrompt;
        if (self.prompts.items.len >= self.options.max_prompts) {
            return error.TooManyPrompts;
        }
        for (self.prompts.items) |existing| {
            if (std.mem.eql(u8, existing.name, prompt.name)) {
                return error.DuplicatePrompt;
            }
        }
        try self.prompts.append(self.allocator, prompt);
    }

    /// HTTP handler for the Streamable HTTP transport.
    ///
    /// Register it on POST and, when `Options.sessions` is enabled, also on
    /// GET (server-initiated SSE) and DELETE (session termination). A
    /// `router.any("/mcp", server.handler(), .{})` route is the simplest setup.
    pub fn handler(self: *Server) Handler {
        return handler_mod.withContext(Server, self, call);
    }

    fn call(self: *Server, ctx: *ctx_mod.Ctx) anyerror!void {
        return switch (ctx.method()) {
            .POST => self.handlePost(ctx),
            .GET => self.handleGet(ctx),
            .DELETE => self.handleDelete(ctx),
            else => {
                ctx.setStatus(405);
                try ctx.setHeader(
                    "Allow",
                    if (self.options.sessions) "GET, POST, DELETE" else "POST",
                );
                return ctx.text("Method Not Allowed");
            },
        };
    }

    fn handlePost(self: *Server, ctx: *ctx_mod.Ctx) anyerror!void {
        if (!self.originAllowed(ctx)) {
            ctx.setStatus(403);
            return ctx.text("Forbidden origin");
        }

        const body = ctx.bodyJson(std.json.Value) catch |err| switch (err) {
            error.UnsupportedMediaType => {
                ctx.setStatus(415);
                return ctx.text("Expected application/json");
            },
            error.PayloadTooLarge => {
                ctx.setStatus(413);
                return ctx.text("Payload Too Large");
            },
            error.InvalidJson => {
                ctx.setStatus(400);
                try ctx.setHeader("Content-Type", "application/json");
                return ctx.json(try errorResponse(
                    ctx.arena,
                    .null,
                    -32700,
                    "Parse error",
                ));
            },
            else => return err,
        };

        if (self.options.sessions) {
            if (isInitializeMessage(body)) {
                const session = self.createSession(ctx.io) catch {
                    ctx.setStatus(503);
                    return ctx.text("Too Many Sessions");
                };
                try ctx.setHeader("Mcp-Session-Id", &session.id);
            } else {
                const id = self.sessionId(ctx) orelse {
                    ctx.setStatus(404);
                    return ctx.text("Session Not Found");
                };
                self.lockSession();
                self.pruneSessionsLocked(ctx.io);
                const session = self.findSessionLocked(id, ctx.io);
                self.unlockSession();
                if (session == null) {
                    ctx.setStatus(404);
                    return ctx.text("Session Not Found");
                }
            }
        }

        switch (body) {
            .array => |array| {
                if (array.items.len > self.options.max_batch_messages) {
                    ctx.setStatus(400);
                    try ctx.setHeader("Content-Type", "application/json");
                    return ctx.json(try errorResponse(
                        ctx.arena,
                        .null,
                        -32600,
                        "Batch too large",
                    ));
                }
                var responses = std.json.Array.init(ctx.arena);
                for (array.items) |message| {
                    if (try self.dispatch(ctx.arena, message)) |response| {
                        try responses.append(response);
                    }
                }
                if (responses.items.len == 0) {
                    ctx.setStatus(202);
                    return;
                }
                try ctx.json(std.json.Value{ .array = responses });
            },
            .object => {
                if (try self.dispatch(ctx.arena, body)) |response| {
                    try ctx.json(response);
                } else {
                    ctx.setStatus(202);
                }
            },
            else => {
                ctx.setStatus(400);
                try ctx.setHeader("Content-Type", "application/json");
                try ctx.json(try errorResponse(
                    ctx.arena,
                    .null,
                    -32600,
                    "Invalid Request",
                ));
            },
        }
    }

    fn handleGet(self: *Server, ctx: *ctx_mod.Ctx) anyerror!void {
        if (!self.originAllowed(ctx)) {
            ctx.setStatus(403);
            return ctx.text("Forbidden origin");
        }
        if (!self.options.sessions) {
            ctx.setStatus(405);
            try ctx.setHeader("Allow", "POST");
            return ctx.text("Method Not Allowed");
        }
        const id = self.sessionId(ctx) orelse {
            ctx.setStatus(404);
            return ctx.text("Session Not Found");
        };
        self.lockSession();
        self.pruneSessionsLocked(ctx.io);
        const session = self.findSessionLocked(id, ctx.io);
        self.unlockSession();
        if (session == null) {
            ctx.setStatus(404);
            return ctx.text("Session Not Found");
        }

        const context = try ctx.arena.create(SseContext);
        context.* = .{
            .server = self,
            .session_id = id,
            .io = ctx.io,
            .poll_interval = self.options.sse_poll_interval,
            .keep_alive_interval = self.options.sse_keep_alive_interval,
            .idle_timeout = self.options.sse_idle_timeout,
        };
        try ctx.sse(.{
            .context = context,
            .write_fn = sseProducer,
        });
    }

    fn handleDelete(self: *Server, ctx: *ctx_mod.Ctx) anyerror!void {
        if (!self.originAllowed(ctx)) {
            ctx.setStatus(403);
            return ctx.text("Forbidden origin");
        }
        if (!self.options.sessions) {
            ctx.setStatus(405);
            try ctx.setHeader("Allow", "POST");
            return ctx.text("Method Not Allowed");
        }
        const id = self.sessionId(ctx) orelse {
            ctx.setStatus(404);
            return ctx.text("Session Not Found");
        };
        self.lockSession();
        const removed = self.sessions.fetchRemove(id);
        if (removed) |entry| self.destroySessionLocked(entry.value);
        self.unlockSession();
        if (removed == null) {
            ctx.setStatus(404);
            return ctx.text("Session Not Found");
        }
        ctx.setStatus(204);
    }

    fn sessionId(self: *const Server, ctx: *const ctx_mod.Ctx) ?[session_id_len]u8 {
        _ = self;
        const value = ctx.header("mcp-session-id") orelse return null;
        if (value.len != session_id_len) return null;
        var id: [session_id_len]u8 = undefined;
        for (value, 0..) |char, index| id[index] = std.ascii.toLower(char);
        return id;
    }

    fn createSession(self: *Server, io: std.Io) !*Session {
        self.lockSession();
        defer self.unlockSession();
        self.pruneSessionsLocked(io);
        if (self.sessions.count() >= self.options.max_sessions) {
            return error.TooManySessions;
        }
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        var random: [session_id_len / 2]u8 = undefined;
        std.Io.random(io, &random);
        const hex = "0123456789abcdef";
        var id: [session_id_len]u8 = undefined;
        for (random, 0..) |byte, index| {
            id[index * 2] = hex[byte >> 4];
            id[index * 2 + 1] = hex[byte & 0xf];
        }
        session.* = .{
            .id = id,
            .last_seen = std.Io.Clock.Timestamp.now(io, .awake),
        };
        try self.sessions.put(self.allocator, id, session);
        return session;
    }

    fn pruneSessionsLocked(self: *Server, io: std.Io) void {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        var expired: std.ArrayListUnmanaged([session_id_len]u8) = .empty;
        defer expired.deinit(self.allocator);
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            const idle = entry.value_ptr.*.last_seen.durationTo(now);
            if (idle.raw.nanoseconds >= self.options.session_idle_timeout.nanoseconds) {
                expired.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (expired.items) |id| {
            if (self.sessions.fetchRemove(id)) |removed| {
                self.destroySessionLocked(removed.value);
            }
        }
    }

    fn findSessionLocked(
        self: *Server,
        id: [session_id_len]u8,
        io: std.Io,
    ) ?*Session {
        const session = self.sessions.get(id) orelse return null;
        session.last_seen = std.Io.Clock.Timestamp.now(io, .awake);
        return session;
    }

    fn lockSession(self: *Server) void {
        while (!self.session_mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn unlockSession(self: *Server) void {
        self.session_mutex.unlock();
    }

    fn destroySessionLocked(self: *Server, session: *Session) void {
        for (session.events.items) |event| self.allocator.free(event);
        session.events.deinit(self.allocator);
        self.allocator.destroy(session);
    }

    fn popEvent(
        self: *Server,
        id: [session_id_len]u8,
        io: std.Io,
    ) ?[]u8 {
        self.lockSession();
        defer self.unlockSession();
        const session = self.sessions.get(id) orelse return null;
        session.last_seen = std.Io.Clock.Timestamp.now(io, .awake);
        if (session.events.items.len == 0) return null;
        return session.events.orderedRemove(0);
    }

    /// Queue one server-initiated JSON-RPC message for a session. The SSE GET
    /// stream delivers it as an `event: message` frame.
    pub fn notify(
        self: *Server,
        session_id: []const u8,
        message: []const u8,
    ) !void {
        if (message.len > self.options.max_event_bytes) {
            return error.EventTooLarge;
        }
        if (session_id.len != session_id_len) return error.InvalidSessionId;
        var id: [session_id_len]u8 = undefined;
        for (session_id, 0..) |char, index| id[index] = std.ascii.toLower(char);
        self.lockSession();
        defer self.unlockSession();
        const session = self.sessions.get(id) orelse
            return error.UnknownSession;
        if (session.events.items.len >= self.options.max_session_events) {
            return error.SessionQueueFull;
        }
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try session.events.append(self.allocator, copy);
    }

    fn isInitializeMessage(body: std.json.Value) bool {
        return switch (body) {
            .object => |object| blk: {
                const method = object.get("method") orelse break :blk false;
                break :blk method == .string and
                    std.mem.eql(u8, method.string, "initialize");
            },
            else => false,
        };
    }

    fn sseProducer(raw: ?*anyopaque, writer: *stream_mod.Writer) anyerror!void {
        const context: *SseContext = @ptrCast(@alignCast(raw orelse
            return error.InvalidWriterState));
        const start = std.Io.Clock.Timestamp.now(context.io, .awake);
        var last_write = start;
        while (true) {
            if (context.server.popEvent(context.session_id, context.io)) |event| {
                defer context.server.allocator.free(event);
                try sse_mod.write(writer, .{
                    .event = "message",
                    .data = event,
                });
                last_write = std.Io.Clock.Timestamp.now(context.io, .awake);
                continue;
            }
            const now = std.Io.Clock.Timestamp.now(context.io, .awake);
            if (start.durationTo(now).raw.nanoseconds >= context.idle_timeout.nanoseconds) {
                return;
            }
            if (last_write.durationTo(now).raw.nanoseconds >=
                context.keep_alive_interval.nanoseconds)
            {
                try sse_mod.comment(writer, "keep-alive");
                last_write = now;
            }
            std.Io.sleep(context.io, context.poll_interval, .awake) catch
                return error.Canceled;
        }
    }

    fn originAllowed(self: *const Server, ctx: *const ctx_mod.Ctx) bool {
        if (self.options.allowed_origins.len == 0) return true;
        const origin = ctx.header("origin") orelse return true;
        for (self.options.allowed_origins) |allowed| {
            if (std.ascii.eqlIgnoreCase(allowed, origin)) return true;
        }
        return false;
    }

    /// Dispatch one JSON-RPC message. Returns null for notifications.
    pub fn dispatch(
        self: *Server,
        arena: std.mem.Allocator,
        message: std.json.Value,
    ) !?std.json.Value {
        const object = switch (message) {
            .object => |object| object,
            else => return try errorResponse(
                arena,
                .null,
                -32600,
                "Invalid Request",
            ),
        };

        const id = object.get("id");
        const is_notification = id == null;

        const jsonrpc = object.get("jsonrpc") orelse
            return if (is_notification)
                null
            else
                try errorResponse(arena, .null, -32600, "Invalid Request");
        if (jsonrpc != .string or
            !std.mem.eql(u8, jsonrpc.string, "2.0"))
        {
            return if (is_notification)
                null
            else
                try errorResponse(arena, .null, -32600, "Invalid Request");
        }

        const method_value = object.get("method") orelse
            return if (is_notification)
                null
            else
                try errorResponse(arena, id.?, -32600, "Invalid Request");
        const method = switch (method_value) {
            .string => |name| name,
            else => return if (is_notification)
                null
            else
                try errorResponse(arena, id.?, -32600, "Invalid Request"),
        };

        const empty_params: std.json.ObjectMap = .empty;
        const params = object.get("params") orelse
            std.json.Value{ .object = empty_params };

        if (is_notification) {
            // `notifications/initialized` and cancellation notifications need
            // no server state in the stateless transport.
            return null;
        }

        const result = self.callMethod(arena, method, params) catch |err| {
            return try errorResponse(
                arena,
                id.?,
                methodErrorCode(err),
                methodErrorMessage(err),
            );
        };
        return try resultResponse(arena, id.?, result);
    }

    fn callMethod(
        self: *Server,
        arena: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
    ) !std.json.Value {
        if (std.mem.eql(u8, method, "initialize")) {
            return self.initialize(arena, params);
        }
        if (std.mem.eql(u8, method, "ping")) {
            return .{ .object = .empty };
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            return self.toolsList(arena);
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            return self.toolsCall(arena, params);
        }
        if (std.mem.eql(u8, method, "resources/list")) {
            return self.resourcesList(arena);
        }
        if (std.mem.eql(u8, method, "resources/read")) {
            return self.resourcesRead(arena, params);
        }
        if (std.mem.eql(u8, method, "prompts/list")) {
            return self.promptsList(arena);
        }
        if (std.mem.eql(u8, method, "prompts/get")) {
            return self.promptsGet(arena, params);
        }
        return error.MethodNotFound;
    }

    fn initialize(
        self: *Server,
        arena: std.mem.Allocator,
        params: std.json.Value,
    ) !std.json.Value {
        const requested = switch (params) {
            .object => |object| blk: {
                const value = object.get("protocolVersion") orelse break :blk null;
                break :blk switch (value) {
                    .string => |version| version,
                    else => null,
                };
            },
            else => null,
        };

        var selected = self.options.protocol_versions[0];
        if (requested) |version| {
            for (self.options.protocol_versions) |supported| {
                if (std.mem.eql(u8, supported, version)) {
                    selected = supported;
                    break;
                }
            }
        }

        var capabilities: std.json.ObjectMap = .empty;
        var tools: std.json.ObjectMap = .empty;
        try tools.put(arena, "listChanged", .{ .bool = false });
        try capabilities.put(arena, "tools", .{ .object = tools });
        var resources: std.json.ObjectMap = .empty;
        try resources.put(arena, "subscribe", .{ .bool = false });
        try resources.put(arena, "listChanged", .{ .bool = false });
        try capabilities.put(arena, "resources", .{ .object = resources });
        var prompts: std.json.ObjectMap = .empty;
        try prompts.put(arena, "listChanged", .{ .bool = false });
        try capabilities.put(arena, "prompts", .{ .object = prompts });

        var server_info: std.json.ObjectMap = .empty;
        try server_info.put(arena, "name", .{ .string = self.options.server_name });
        try server_info.put(
            arena,
            "version",
            .{ .string = self.options.server_version },
        );

        var result: std.json.ObjectMap = .empty;
        try result.put(arena, "protocolVersion", .{ .string = selected });
        try result.put(arena, "capabilities", .{ .object = capabilities });
        try result.put(arena, "serverInfo", .{ .object = server_info });
        if (self.options.instructions) |instructions| {
            try result.put(arena, "instructions", .{ .string = instructions });
        }
        return .{ .object = result };
    }

    fn toolsList(self: *Server, arena: std.mem.Allocator) !std.json.Value {
        var tools = std.json.Array.init(arena);
        for (self.tools.items) |tool| {
            var item: std.json.ObjectMap = .empty;
            try item.put(arena, "name", .{ .string = tool.name });
            if (tool.title) |title| {
                try item.put(arena, "title", .{ .string = title });
            }
            if (tool.description) |description| {
                try item.put(arena, "description", .{ .string = description });
            }
            try item.put(
                arena,
                "inputSchema",
                try std.json.parseFromSliceLeaky(
                    std.json.Value,
                    arena,
                    tool.input_schema_json,
                    .{},
                ),
            );
            if (tool.output_schema_json) |schema| {
                try item.put(
                    arena,
                    "outputSchema",
                    try std.json.parseFromSliceLeaky(
                        std.json.Value,
                        arena,
                        schema,
                        .{},
                    ),
                );
            }
            const annotations = try annotationsValue(arena, tool.annotations);
            if (annotations) |value| {
                try item.put(arena, "annotations", value);
            }
            try tools.append(.{ .object = item });
        }
        var result: std.json.ObjectMap = .empty;
        try result.put(arena, "tools", .{ .array = tools });
        return .{ .object = result };
    }

    fn toolsCall(
        self: *Server,
        arena: std.mem.Allocator,
        params: std.json.Value,
    ) !std.json.Value {
        const object = switch (params) {
            .object => |object| object,
            else => return error.InvalidParams,
        };
        const name = switch (object.get("name") orelse
            return error.InvalidParams) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        const tool = self.findTool(name) orelse return error.UnknownTool;

        var tool_ctx = ToolContext.init(arena);
        if (object.get("arguments")) |arguments| {
            tool_ctx.arguments = arguments;
        }

        var execution_error: ?anyerror = null;
        tool.handler(&tool_ctx) catch |err| {
            execution_error = err;
        };
        if (execution_error) |err| {
            tool_ctx.is_error = true;
            if (tool_ctx.content.items.len == 0) {
                try tool_ctx.text(try std.fmt.allocPrint(
                    arena,
                    "Tool execution failed: {s}",
                    .{@errorName(err)},
                ));
            }
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(arena, "content", .{ .array = tool_ctx.content });
        if (tool_ctx.structured) |structured| {
            try result.put(arena, "structuredContent", structured);
        }
        if (tool_ctx.is_error) {
            try result.put(arena, "isError", .{ .bool = true });
        }
        return .{ .object = result };
    }

    fn resourcesList(
        self: *Server,
        arena: std.mem.Allocator,
    ) !std.json.Value {
        var resources = std.json.Array.init(arena);
        for (self.resources.items) |resource| {
            var item: std.json.ObjectMap = .empty;
            try item.put(arena, "uri", .{ .string = resource.uri });
            try item.put(arena, "name", .{ .string = resource.name });
            if (resource.title) |title| {
                try item.put(arena, "title", .{ .string = title });
            }
            if (resource.description) |description| {
                try item.put(arena, "description", .{ .string = description });
            }
            if (resource.mime_type) |mime_type| {
                try item.put(arena, "mimeType", .{ .string = mime_type });
            }
            try resources.append(.{ .object = item });
        }
        var result: std.json.ObjectMap = .empty;
        try result.put(arena, "resources", .{ .array = resources });
        return .{ .object = result };
    }

    fn resourcesRead(
        self: *Server,
        arena: std.mem.Allocator,
        params: std.json.Value,
    ) !std.json.Value {
        const object = switch (params) {
            .object => |object| object,
            else => return error.InvalidParams,
        };
        const uri = switch (object.get("uri") orelse
            return error.InvalidParams) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        for (self.resources.items) |resource| {
            if (!std.mem.eql(u8, resource.uri, uri)) continue;
            var content: std.json.ObjectMap = .empty;
            try content.put(arena, "uri", .{ .string = resource.uri });
            if (resource.mime_type) |mime_type| {
                try content.put(arena, "mimeType", .{ .string = mime_type });
            }
            try content.put(arena, "text", .{ .string = resource.text });
            var contents = std.json.Array.init(arena);
            try contents.append(.{ .object = content });
            var result: std.json.ObjectMap = .empty;
            try result.put(arena, "contents", .{ .array = contents });
            return .{ .object = result };
        }
        return error.UnknownResource;
    }

    fn promptsList(self: *Server, arena: std.mem.Allocator) !std.json.Value {
        var prompts = std.json.Array.init(arena);
        for (self.prompts.items) |prompt| {
            var item: std.json.ObjectMap = .empty;
            try item.put(arena, "name", .{ .string = prompt.name });
            if (prompt.title) |title| {
                try item.put(arena, "title", .{ .string = title });
            }
            if (prompt.description) |description| {
                try item.put(arena, "description", .{ .string = description });
            }
            if (prompt.arguments.len != 0) {
                var arguments = std.json.Array.init(arena);
                for (prompt.arguments) |argument| {
                    var argument_value: std.json.ObjectMap = .empty;
                    try argument_value.put(
                        arena,
                        "name",
                        .{ .string = argument.name },
                    );
                    if (argument.description) |description| {
                        try argument_value.put(
                            arena,
                            "description",
                            .{ .string = description },
                        );
                    }
                    if (argument.required) {
                        try argument_value.put(
                            arena,
                            "required",
                            .{ .bool = true },
                        );
                    }
                    try arguments.append(.{ .object = argument_value });
                }
                try item.put(arena, "arguments", .{ .array = arguments });
            }
            try prompts.append(.{ .object = item });
        }
        var result: std.json.ObjectMap = .empty;
        try result.put(arena, "prompts", .{ .array = prompts });
        return .{ .object = result };
    }

    fn promptsGet(
        self: *Server,
        arena: std.mem.Allocator,
        params: std.json.Value,
    ) !std.json.Value {
        const object = switch (params) {
            .object => |object| object,
            else => return error.InvalidParams,
        };
        const name = switch (object.get("name") orelse
            return error.InvalidParams) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        var prompt: ?Prompt = null;
        for (self.prompts.items) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) {
                prompt = candidate;
                break;
            }
        }
        const selected = prompt orelse return error.UnknownPrompt;

        var supplied: std.json.ObjectMap = .empty;
        if (object.get("arguments")) |arguments| {
            switch (arguments) {
                .object => |map| supplied = map,
                else => return error.InvalidParams,
            }
        }
        for (selected.arguments) |argument| {
            if (!argument.required) continue;
            const value = supplied.get(argument.name) orelse
                return error.MissingPromptArgument;
            if (value != .string) return error.InvalidParams;
        }

        var messages = std.json.Array.init(arena);
        for (selected.messages) |message| {
            const text = try substitutePrompt(
                arena,
                message.text,
                &supplied,
            );
            var content: std.json.ObjectMap = .empty;
            try content.put(arena, "type", .{ .string = "text" });
            try content.put(arena, "text", .{ .string = text });
            var message_value: std.json.ObjectMap = .empty;
            try message_value.put(
                arena,
                "role",
                .{ .string = @tagName(message.role) },
            );
            try message_value.put(arena, "content", .{ .object = content });
            try messages.append(.{ .object = message_value });
        }

        var result: std.json.ObjectMap = .empty;
        if (selected.description) |description| {
            try result.put(arena, "description", .{ .string = description });
        }
        try result.put(arena, "messages", .{ .array = messages });
        return .{ .object = result };
    }

    fn findTool(self: *Server, name: []const u8) ?Tool {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }
};

fn annotationsValue(
    arena: std.mem.Allocator,
    annotations: ToolAnnotations,
) !?std.json.Value {
    if (annotations.raw_json) |raw| {
        return try std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            raw,
            .{},
        );
    }
    var value: std.json.ObjectMap = .empty;
    var any = false;
    if (annotations.title) |title| {
        try value.put(arena, "title", .{ .string = title });
        any = true;
    }
    if (annotations.read_only_hint) {
        try value.put(arena, "readOnlyHint", .{ .bool = true });
        any = true;
    }
    if (annotations.destructive_hint) {
        try value.put(arena, "destructiveHint", .{ .bool = true });
        any = true;
    }
    if (annotations.idempotent_hint) {
        try value.put(arena, "idempotentHint", .{ .bool = true });
        any = true;
    }
    if (annotations.open_world_hint) {
        try value.put(arena, "openWorldHint", .{ .bool = true });
        any = true;
    }
    return if (any) std.json.Value{ .object = value } else null;
}

fn substitutePrompt(
    arena: std.mem.Allocator,
    template: []const u8,
    arguments: *const std.json.ObjectMap,
) ![]const u8 {
    var output = std.array_list.Managed(u8).init(arena);
    var index: usize = 0;
    while (index < template.len) {
        const start = std.mem.indexOfPos(
            u8,
            template,
            index,
            "{{",
        ) orelse {
            try output.appendSlice(template[index..]);
            break;
        };
        const end = std.mem.indexOfPos(
            u8,
            template,
            start + 2,
            "}}",
        ) orelse {
            try output.appendSlice(template[index..]);
            break;
        };
        try output.appendSlice(template[index..start]);
        const name = std.mem.trim(u8, template[start + 2 .. end], " \t");
        if (arguments.get(name)) |value| {
            switch (value) {
                .string => |string| try output.appendSlice(string),
                else => try output.appendSlice(template[start .. end + 2]),
            }
        } else {
            try output.appendSlice(template[start .. end + 2]);
        }
        index = end + 2;
    }
    return output.toOwnedSlice();
}

fn validateJsonObject(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw,
        .{},
    ) catch return error.InvalidJsonSchema;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonSchema;
}

fn resultResponse(
    arena: std.mem.Allocator,
    id: std.json.Value,
    result: std.json.Value,
) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "jsonrpc", .{ .string = "2.0" });
    try object.put(arena, "id", id);
    try object.put(arena, "result", result);
    return .{ .object = object };
}

fn errorResponse(
    arena: std.mem.Allocator,
    id: std.json.Value,
    code: i64,
    message: []const u8,
) !std.json.Value {
    var error_object: std.json.ObjectMap = .empty;
    try error_object.put(arena, "code", .{ .integer = code });
    try error_object.put(arena, "message", .{ .string = message });
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "jsonrpc", .{ .string = "2.0" });
    try object.put(arena, "id", id);
    try object.put(arena, "error", .{ .object = error_object });
    return .{ .object = object };
}

fn methodErrorCode(err: anyerror) i64 {
    return switch (err) {
        error.MethodNotFound => -32601,
        error.InvalidParams,
        error.UnknownTool,
        error.UnknownResource,
        error.UnknownPrompt,
        error.MissingPromptArgument,
        => -32602,
        else => -32603,
    };
}

fn methodErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MethodNotFound => "Method not found",
        error.InvalidParams => "Invalid params",
        error.UnknownTool => "Unknown tool",
        error.UnknownResource => "Unknown resource",
        error.UnknownPrompt => "Unknown prompt",
        error.MissingPromptArgument => "Missing prompt argument",
        else => "Internal error",
    };
}
