//! Serves the same router as an HTTP API, an OpenAPI 3.1 document, and an MCP
//! server. Run with `zig build run-agent` and try:
//!
//!   curl http://127.0.0.1:8080/hello/weft
//!   curl http://127.0.0.1:8080/openapi.json
//!   curl -X POST http://127.0.0.1:8080/mcp \
//!     -H 'content-type: application/json' \
//!     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

const std = @import("std");
const weft = @import("weft");
const netz = @import("netz");

const App = struct {};

fn hello(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const name = ctx.param("name") orelse "stranger";
    try ctx.json(.{ .message = "hello", .name = name });
}

fn echoTool(tool_ctx: *weft.mcp.ToolContext) anyerror!void {
    const message = tool_ctx.stringArgument("message") orelse "";
    try tool_ctx.text(message);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var backend = try netz.runtime.Backend.init(allocator);
    defer backend.deinit();
    const io = backend.io();

    var mcp_server = weft.mcp.Server.init(allocator, .{
        .server_name = "weft-agent",
        .server_version = "0.1.0",
        .instructions = "Call the echo tool or read the weft://readme resource.",
    });
    defer mcp_server.deinit();
    try mcp_server.addTool(.{
        .name = "echo",
        .description = "Echo a message",
        .input_schema_json =
        \\{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}
        ,
        .handler = echoTool,
    });
    try mcp_server.addResource(.{
        .uri = "weft://readme",
        .name = "readme",
        .mime_type = "text/plain",
        .text = "weft exposes OpenAPI and MCP from the same router.",
    });

    var server = try weft.Server(App).init(
        io,
        allocator,
        .{ .address = .{ .ip4 = .loopback(8080) } },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/hello/:name", hello, .{
        .openapi = .{
            .summary = "Greet a caller",
            .operation_id = "greet",
            .tags = &.{"greeting"},
            .parameters = &.{
                .{
                    .name = "name",
                    .location = .path,
                    .schema = .{ .type = "string" },
                },
            },
            .responses = &.{
                .{
                    .status = 200,
                    .description = "Greeting",
                    .content_type = "application/json",
                    .schema = .{ .type = "object" },
                },
            },
        },
    });

    const routes = try router.openapiRoutes(allocator);
    defer allocator.free(routes);
    var document = try weft.openapi.Document.init(allocator, routes, .{
        .info = .{ .title = "weft agent", .version = "0.1.0" },
        .ui = .{ .json_url = "/openapi.json" },
    });
    defer document.deinit();
    try router.addRaw(.GET, "/openapi.json", document.handler(), .{});
    try router.addRaw(.GET, "/docs", document.uiHandler(), .{});
    try router.addRaw(.POST, "/mcp", mcp_server.handler(), .{});

    std.debug.print(
        "weft agent listening on http://{f}\n",
        .{server.address()},
    );
    try server.serve();
}
