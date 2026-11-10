const std = @import("std");

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
    /// Enable stateful Streamable HTTP sessions. `initialize` assigns an
    /// `Mcp-Session-Id`; subsequent POST/GET/DELETE requests must present it.
    sessions: bool = false,
    /// Maximum live sessions retained by one server.
    max_sessions: usize = 64,
    /// Idle sessions older than this are pruned on the next session access.
    session_idle_timeout: std.Io.Duration = .fromSeconds(30 * 60),
    /// Maximum queued server-initiated messages per session.
    max_session_events: usize = 64,
    /// Maximum bytes for one server-initiated message.
    max_event_bytes: usize = 64 * 1024,
    /// Poll interval for the server-initiated SSE stream.
    sse_poll_interval: std.Io.Duration = .fromMilliseconds(25),
    /// Keep-alive comment interval for the SSE stream.
    sse_keep_alive_interval: std.Io.Duration = .fromSeconds(15),
    /// Maximum lifetime of one SSE GET stream.
    sse_idle_timeout: std.Io.Duration = .fromSeconds(5 * 60),
};
