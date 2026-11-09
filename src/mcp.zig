//! Model Context Protocol (MCP) server support over the Streamable HTTP
//! transport.
//!
//! `Server` owns a bounded registry of tools, resources, and prompts. Register
//! it as a `POST` route; the handler accepts JSON-RPC 2.0 messages, answers
//! `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`,
//! `resources/read`, `prompts/list`, and `prompts/get`, and returns `202` for
//! notifications. Responses use a single `application/json` body, which the
//! Streamable HTTP transport permits.
//!
//! Registration is startup-only and bounded by `Options.max_tools`,
//! `max_resources`, and `max_prompts`. Request bodies are bounded by the
//! server's `Limits.max_body_bytes` and responses by
//! `Limits.max_response_bytes`.

const std = @import("std");
const ctx_mod = @import("ctx.zig");

pub const Handler = ctx_mod.Handler;

pub const Role = enum { user, assistant };

pub const ToolAnnotations = struct {
    title: ?[]const u8 = null,
    read_only_hint: bool = false,
    destructive_hint: bool = false,
    idempotent_hint: bool = false,
    open_world_hint: bool = false,
    /// Complete JSON object that replaces the generated annotations object.
    raw_json: ?[]const u8 = null,
};

/// Mutable result of one `tools/call`. Strings passed to `text` and `fail`
/// are copied into the request arena, so they may be stack temporaries.
pub const ToolContext = struct {
    arena: std.mem.Allocator,
    /// Parsed `arguments` object; `.null` when the request omitted it.
    arguments: std.json.Value = .null,
    content: std.json.Array,
    structured: ?std.json.Value = null,
    is_error: bool = false,

    pub fn init(arena: std.mem.Allocator) ToolContext {
        return .{
            .arena = arena,
            .content = std.json.Array.init(arena),
        };
    }

    /// Append a `text` content item.
    pub fn text(self: *ToolContext, value: []const u8) !void {
        var item: std.json.ObjectMap = .empty;
        try item.put(self.arena, "type", .{ .string = "text" });
        try item.put(
            self.arena,
            "text",
            .{ .string = try self.arena.dupe(u8, value) },
        );
        try self.content.append(.{ .object = item });
    }

    /// Serialize `value` as JSON and append it as a `text` content item.
    pub fn json(self: *ToolContext, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(
            self.arena,
            value,
            .{},
        );
        try self.text(bytes);
    }

    /// Set `structuredContent` from a serializable value.
    pub fn structuredJson(self: *ToolContext, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(
            self.arena,
            value,
            .{},
        );
        self.structured = try std.json.parseFromSliceLeaky(
            std.json.Value,
            self.arena,
            bytes,
            .{},
        );
    }

    /// Mark the result as an execution error and append a text item.
    pub fn fail(self: *ToolContext, message: []const u8) !void {
        self.is_error = true;
        try self.text(message);
    }

    pub fn argument(self: *const ToolContext, name: []const u8) ?std.json.Value {
        return switch (self.arguments) {
            .object => |object| object.get(name),
            else => null,
        };
    }

    pub fn stringArgument(
        self: *const ToolContext,
        name: []const u8,
    ) ?[]const u8 {
        const value = self.argument(name) orelse return null;
        return switch (value) {
            .string => |string| string,
            else => null,
        };
    }

    pub fn integerArgument(self: *const ToolContext, name: []const u8) ?i64 {
        const value = self.argument(name) orelse return null;
        return switch (value) {
            .integer => |integer| integer,
            else => null,
        };
    }

    pub fn boolArgument(self: *const ToolContext, name: []const u8) ?bool {
        const value = self.argument(name) orelse return null;
        return switch (value) {
            .bool => |boolean| boolean,
            else => null,
        };
    }
};

pub const ToolHandler = *const fn (*ToolContext) anyerror!void;

pub const Tool = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// JSON Schema object for `inputSchema`. Validated at registration.
    input_schema_json: []const u8 = "{\"type\":\"object\"}",
    /// Optional JSON Schema object for `outputSchema`.
    output_schema_json: ?[]const u8 = null,
    annotations: ToolAnnotations = .{},
    handler: ToolHandler,
};

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    text: []const u8,
};

pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: bool = false,
};

pub const PromptMessage = struct {
    role: Role = .user,
    text: []const u8,
};

pub const Prompt = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    arguments: []const PromptArgument = &.{},
    messages: []const PromptMessage = &.{},
};

pub const Options = struct {
    server_name: []const u8 = "weft",
    server_version: []const u8 = "0.1.0",
    instructions: ?[]const u8 = null,
    max_tools: usize = 64,
    max_resources: usize = 64,
    max_prompts: usize = 64,
    max_batch_messages: usize = 16,
    /// Browser origins allowed to call the endpoint. Empty allows any origin;
    /// requests without an `Origin` header (non-browser clients) are always
    /// allowed. Set this for browser-facing deployments to prevent DNS
    /// rebinding.
    allowed_origins: []const []const u8 = &.{},
    /// Supported protocol versions, newest first.
    protocol_versions: []const []const u8 = &.{
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    },
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    options: Options,
    tools: std.ArrayListUnmanaged(Tool) = .empty,
    resources: std.ArrayListUnmanaged(Resource) = .empty,
    prompts: std.ArrayListUnmanaged(Prompt) = .empty,

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

    /// HTTP handler for the Streamable HTTP transport. Register it on a POST
    /// route, for example `router.post("/mcp", server.handler(), .{})`.
    pub fn handler(self: *Server) Handler {
        return ctx_mod.withContext(Server, self, call);
    }

    fn call(self: *Server, ctx: *ctx_mod.Ctx) anyerror!void {
        if (ctx.method() != .POST) {
            ctx.setStatus(405);
            try ctx.setHeader("Allow", "POST");
            return ctx.text("Method Not Allowed");
        }
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

fn echoTool(tool_ctx: *ToolContext) anyerror!void {
    const message = tool_ctx.stringArgument("message") orelse "";
    try tool_ctx.text(message);
}

fn failingTool(tool_ctx: *ToolContext) anyerror!void {
    _ = tool_ctx;
    return error.ToolBoom;
}

test "mcp initializes, lists tools, and calls them" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = Server.init(allocator, .{
        .server_name = "test-server",
        .server_version = "9.9.9",
        .instructions = "be nice",
    });
    defer server.deinit();
    try server.addTool(.{
        .name = "echo",
        .description = "Echo a message",
        .input_schema_json =
        \\{"type":"object","properties":{"message":{"type":"string"}}}
        ,
        .handler = echoTool,
    });
    try server.addResource(.{
        .uri = "weft://readme",
        .name = "readme",
        .mime_type = "text/plain",
        .text = "hello resource",
    });
    try server.addPrompt(.{
        .name = "greet",
        .arguments = &.{
            .{ .name = "name", .required = true },
        },
        .messages = &.{
            .{ .text = "Hello {{name}}!" },
        },
    });

    const initialize = try dispatchText(
        &server,
        arena,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
        ,
    );
    const init_result = initialize.object.get("result").?.object;
    try std.testing.expectEqualStrings(
        "2025-06-18",
        init_result.get("protocolVersion").?.string,
    );
    try std.testing.expectEqualStrings(
        "test-server",
        init_result.get("serverInfo").?.object.get("name").?.string,
    );
    try std.testing.expect(
        init_result.get("capabilities").?.object.get("tools") != null,
    );

    const list = try dispatchText(
        &server,
        arena,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        ,
    );
    const tools = list.object.get("result").?.object
        .get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings(
        "echo",
        tools[0].object.get("name").?.string,
    );
    try std.testing.expectEqualStrings(
        "object",
        tools[0].object.get("inputSchema").?.object.get("type").?.string,
    );

    const called = try dispatchText(
        &server,
        arena,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hi"}}}
        ,
    );
    const content = called.object.get("result").?.object
        .get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), content.len);
    try std.testing.expectEqualStrings(
        "hi",
        content[0].object.get("text").?.string,
    );

    const read = try dispatchText(
        &server,
        arena,
        \\{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"weft://readme"}}
        ,
    );
    const contents = read.object.get("result").?.object
        .get("contents").?.array.items;
    try std.testing.expectEqualStrings(
        "hello resource",
        contents[0].object.get("text").?.string,
    );

    const prompt = try dispatchText(
        &server,
        arena,
        \\{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"greet","arguments":{"name":"weft"}}}
        ,
    );
    const messages = prompt.object.get("result").?.object
        .get("messages").?.array.items;
    try std.testing.expectEqualStrings(
        "Hello weft!",
        messages[0].object.get("content").?.object.get("text").?.string,
    );
}

test "mcp reports unknown methods and tool failures" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = Server.init(allocator, .{});
    defer server.deinit();
    try server.addTool(.{
        .name = "boom",
        .handler = failingTool,
    });

    const unknown = try dispatchText(
        &server,
        arena,
        \\{"jsonrpc":"2.0","id":7,"method":"nope"}
        ,
    );
    try std.testing.expectEqual(
        @as(i64, -32601),
        unknown.object.get("error").?.object.get("code").?.integer,
    );

    const failed = try dispatchText(
        &server,
        arena,
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"boom"}}
        ,
    );
    const result = failed.object.get("result").?.object;
    try std.testing.expect(result.get("isError").?.bool);
    try std.testing.expectEqualStrings(
        "text",
        result.get("content").?.array.items[0].object.get("type").?.string,
    );
}

test "mcp notifications produce no response" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = Server.init(allocator, .{});
    defer server.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(
        try server.dispatch(arena, parsed.value) == null,
    );
}

fn dispatchText(
    server: *Server,
    arena: std.mem.Allocator,
    text: []const u8,
) !std.json.Value {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena,
        text,
        .{},
    );
    return (try server.dispatch(arena, parsed.value)).?;
}
