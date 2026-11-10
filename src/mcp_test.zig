const std = @import("std");
const types = @import("mcp/types.zig");
const server_mod = @import("mcp/server.zig");

const Server = server_mod.Server;
const ToolContext = types.ToolContext;

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
