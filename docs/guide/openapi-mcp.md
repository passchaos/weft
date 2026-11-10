# OpenAPI and MCP

Route metadata rendered as OpenAPI 3.1, and the Model Context Protocol server
over Streamable HTTP.

[Back to the documentation index](../README.md)

## OpenAPI

Attach OpenAPI metadata to any route with `RouteOptions.openapi`; the router
projects the registered routes with `Router.openapiRoutes`, and
`weft.openapi.Document` renders an OpenAPI 3.1 JSON document:

```zig
try router.get("/hello/:name", hello, .{
    .openapi = .{
        .summary = "Greet a caller",
        .operation_id = "greet",
        .responses = &.{.{
            .status = 200,
            .description = "Greeting",
            .content_type = "application/json",
            .schema = .{ .type = "object" },
        }},
    },
});

const routes = try router.openapiRoutes(gpa);
defer gpa.free(routes);
var document = try weft.openapi.Document.init(gpa, routes, .{
    .info = .{ .title = "weft API", .version = "1.0.0" },
    .ui = .{ .json_url = "/openapi.json" },
});
defer document.deinit();
try router.addRaw(.GET, "/openapi.json", document.handler(), .{});
try router.addRaw(.GET, "/docs", document.uiHandler(), .{});
```

- `:name` captures become `{name}` path parameters; a trailing `*` becomes
  `{path}`. Path parameters are generated automatically, and an explicit
  `path` parameter with the same name replaces the generated schema.
  `query`, `header`, and `cookie` parameters are emitted as declared.
- `Schema` covers the common JSON Schema subset (`type`, `format`,
  `properties`, `required`, `items`, `enum`, `example`, `default`, `nullable`,
  `additionalProperties`). Set `raw_json` on a schema, security scheme, or
  `Options.security_json` to supply complete JSON; raw JSON is parsed and
  validated when the document is built.
- `router.any` routes expand to `Options.any_methods` (GET, POST, PUT, PATCH,
  and DELETE by default) without shadowing explicit routes on the same path.
- Operation metadata supports `summary`, `description`, `operation_id`, `tags`,
  `deprecated`, `parameters`, `request_body`, `responses`, `security`, and
  `hidden`.
- `Document.init` owns the rendered bytes; keep the `Document` value alive for
  as long as the routes serve it. `uiHandler` serves a Swagger UI page that
  loads CDN assets by default; override `UiOptions` URLs for offline
  deployments.

## MCP

`weft.mcp.Server` implements the server side of the Model Context Protocol
over the Streamable HTTP transport. Register tools, resources, and prompts at
startup, then mount the handler on a POST route:

```zig
fn echoTool(tool_ctx: *weft.mcp.ToolContext) anyerror!void {
    const message = tool_ctx.stringArgument("message") orelse "";
    try tool_ctx.text(message);
}

var mcp_server = weft.mcp.Server.init(gpa, .{
    .server_name = "weft-agent",
    .server_version = "0.1.0",
});
defer mcp_server.deinit();
try mcp_server.addTool(.{
    .name = "echo",
    .description = "Echo a message",
    .input_schema_json =
        "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}}}",
    .handler = echoTool,
});
try router.addRaw(.POST, "/mcp", mcp_server.handler(), .{});
```

- Methods: `initialize`, `ping`, `tools/list`, `tools/call`,
  `resources/list`, `resources/read`, `prompts/list`, and `prompts/get`.
  Notifications (`notifications/initialized`, cancellation) return `202` with
  no body.
- Responses use a single `application/json` body. JSON-RPC batches are
  accepted up to `Options.max_batch_messages`.
- `ToolContext` exposes the parsed `arguments`, typed helpers
  (`stringArgument`, `integerArgument`, `boolArgument`), and result builders
  (`text`, `json`, `structuredJson`, `fail`). A handler error becomes a result
  with `isError: true`; protocol errors use JSON-RPC error codes.
- Tool, resource, and prompt registration is bounded by `max_tools`,
  `max_resources`, and `max_prompts`; schemas are validated as JSON objects at
  registration. Request and response sizes stay bounded by the server
  `Limits`.
- `prompts/get` substitutes `{{name}}` placeholders from the supplied
  arguments and rejects missing required arguments.
- The default transport is stateless: no `Mcp-Session-Id` is issued, and the
  handler only accepts `POST`. Set `Options.sessions = true` to enable
  Streamable HTTP sessions: `initialize` assigns an `Mcp-Session-Id`,
  subsequent requests must present it, `GET` opens a server-initiated SSE
  stream, and `DELETE` terminates the session. Register the handler on all
  three methods in that mode, for example with three `addRaw` routes.
- `Server.notify(session_id, json)` queues a server-initiated JSON-RPC message
  for the session's SSE stream. Queues and event sizes are bounded by
  `max_session_events` and `max_event_bytes`.
- Set `Options.allowed_origins` for browser-facing deployments; requests
  without an `Origin` header are always allowed, and an empty list allows any
  origin.

