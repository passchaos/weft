const std = @import("std");
const weft = @import("weft");
const netz = weft.netz;
const support = @import("support.zig");

const App = support.App;
const clientInfo = support.clientInfo;
const hello = support.hello;
const home = support.home;
const mcpEchoTool = support.mcpEchoTool;
const serveServer = support.serveServer;

test "package: openapi document reflects route metadata" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .max_requests_per_connection = 4,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/hello/:name", home, .{
        .openapi = .{
            .summary = "Greet a caller",
            .operation_id = "greet",
            .parameters = &.{
                .{
                    .name = "lang",
                    .location = .query,
                    .schema = .{ .type = "string" },
                },
            },
            .responses = &.{
                .{
                    .status = 200,
                    .description = "Greeting",
                    .content_type = "text/plain",
                },
            },
        },
    });

    const routes = try router.openapiRoutes(allocator);
    defer allocator.free(routes);
    var document = try weft.openapi.Document.init(allocator, routes, .{
        .info = .{ .title = "weft package test", .version = "1.0.0" },
    });
    defer document.deinit();
    try router.addRaw(.GET, "/openapi.json", document.handler(), .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/openapi.json",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    var response = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{},
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.response.status);
    try std.testing.expectEqualStrings(
        "application/json",
        response.response.header("content-type").?,
    );

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        response.response.body,
        .{},
    );
    defer parsed.deinit();
    const path = parsed.value.object.get("paths").?.object
        .get("/hello/{name}").?.object.get("get").?.object;
    try std.testing.expectEqualStrings(
        "greet",
        path.get("operationId").?.string,
    );
    const parameters = path.get("parameters").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), parameters.len);
    try std.testing.expectEqualStrings(
        "name",
        parameters[0].object.get("name").?.string,
    );
    try std.testing.expectEqualStrings(
        "path",
        parameters[0].object.get("in").?.string,
    );

    server.stop();
    try group.await(io);
}

test "package: mcp initialize, tools/list, tools/call, and notifications" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var mcp_server = weft.mcp.Server.init(allocator, .{
        .server_name = "weft-test",
        .server_version = "0.0.1",
        .allowed_origins = &.{"https://app.example"},
    });
    defer mcp_server.deinit();
    try mcp_server.addTool(.{
        .name = "echo",
        .description = "Echo a message",
        .input_schema_json =
        \\{"type":"object","properties":{"message":{"type":"string"}}}
        ,
        .handler = mcpEchoTool,
    });

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .max_requests_per_connection = 8,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.addRaw(.POST, "/mcp", mcp_server.handler(), .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/mcp",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    const json_headers = [_]netz.http1.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    const initialize_body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
    ;
    var initialize = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &json_headers,
            .body = initialize_body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer initialize.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), initialize.response.status);
    var initialize_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        initialize.response.body,
        .{},
    );
    defer initialize_json.deinit();
    try std.testing.expectEqualStrings(
        "weft-test",
        initialize_json.value.object.get("result").?.object
            .get("serverInfo").?.object.get("name").?.string,
    );

    const call_body =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hi"}}}
    ;
    var call = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &json_headers,
            .body = call_body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer call.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), call.response.status);
    var call_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        call.response.body,
        .{},
    );
    defer call_json.deinit();
    const content = call_json.value.object.get("result").?.object
        .get("content").?.array.items;
    try std.testing.expectEqualStrings(
        "hi",
        content[0].object.get("text").?.string,
    );

    const notification_body =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;
    var notification = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &json_headers,
            .body = notification_body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer notification.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 202),
        notification.response.status,
    );
    try std.testing.expectEqualStrings("", notification.response.body);

    const evil_headers = [_]netz.http1.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Origin", .value = "https://evil.example" },
    };
    var forbidden = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &evil_headers,
            .body = notification_body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer forbidden.deinit(allocator);
    try std.testing.expectEqual(
        @as(u16, 403),
        forbidden.response.status,
    );

    server.stop();
    try group.await(io);
}

fn mcpResponseHeader(
    response: *const netz.http1.runtime.OwnedResponse,
    name: []const u8,
) ?[]const u8 {
    for (response.response.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

test "package: mcp sessions, server notifications, and SSE" {
    const allocator = std.testing.allocator;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var mcp_server = weft.mcp.Server.init(allocator, .{
        .server_name = "weft-session-test",
        .sessions = true,
        .sse_idle_timeout = .fromMilliseconds(100),
        .sse_poll_interval = .fromMilliseconds(5),
        .sse_keep_alive_interval = .fromMilliseconds(40),
    });
    defer mcp_server.deinit();
    try mcp_server.addTool(.{
        .name = "echo",
        .handler = mcpEchoTool,
    });

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{
            .address = .{ .ip4 = .loopback(0) },
            .limits = .{
                .max_head_bytes = 4096,
                .max_body_bytes = 4096,
                .max_request_arena_bytes = 64 * 1024,
                .max_response_bytes = 64 * 1024,
            },
            .max_connections = 1,
            .max_requests_per_connection = 8,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.addRaw(.GET, "/mcp", mcp_server.handler(), .{});
    try router.addRaw(.POST, "/mcp", mcp_server.handler(), .{});
    try router.addRaw(.DELETE, "/mcp", mcp_server.handler(), .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveServer, .{&server});

    const uri = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/mcp",
        .{server.address().ip4.port},
    );
    defer allocator.free(uri);

    const json_headers = [_]netz.http1.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const initialize_body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
    ;
    var initialize = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &json_headers,
            .body = initialize_body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer initialize.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), initialize.response.status);
    const id_value = mcpResponseHeader(&initialize, "mcp-session-id") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 32), id_value.len);
    var session_id: [32]u8 = undefined;
    @memcpy(&session_id, id_value);

    const with_session = [_]netz.http1.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Mcp-Session-Id", .value = &session_id },
    };
    const list_body =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    ;
    var list = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &with_session,
            .body = list_body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), list.response.status);

    var missing = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &json_headers,
            .body = list_body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), missing.response.status);

    try mcp_server.notify(&session_id,
        \\{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"hello"}}
    );

    const sse_headers = [_]netz.http1.Header{
        .{ .name = "Accept", .value = "text/event-stream" },
        .{ .name = "Mcp-Session-Id", .value = &session_id },
    };
    var stream = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .GET,
            .headers = &sse_headers,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer stream.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), stream.response.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        stream.response.body,
        "event: message",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        stream.response.body,
        "hello",
    ) != null);

    var deleted = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .DELETE,
            .headers = &with_session,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer deleted.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 204), deleted.response.status);

    var after_delete = try netz.http1.runtime.Client.requestUri(
        allocator,
        io,
        uri,
        .{
            .method = .POST,
            .headers = &with_session,
            .body = list_body,
        },
        .{ .max_head_bytes = 4096, .max_body_bytes = 64 * 1024 },
    );
    defer after_delete.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), after_delete.response.status);

    server.stop();
    try group.await(io);
}
