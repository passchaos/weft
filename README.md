# weft

`weft` is the application weaving layer on top of [`netz`](../netz): routing,
middleware, typed request locals, and a bounded HTTP/1 server adapter for Zig
0.16.

The split is deliberate:

- **netz** owns protocol codecs, connection state machines, and HTTP/1 framing.
- **weft** owns application dispatch: concrete `Ctx`, `Handler`, `Router`,
  middleware, and per-request budgets.
- **`std.Io`** is the runtime seam. `zio` can back it today; another `std.Io`
  implementation can replace it without changing protocol or application code.

## Shape

```zig
const std = @import("std");
const weft = @import("weft");
const netz = @import("netz");

const App = struct {};

fn home(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.text("hello from weft");
}

fn hello(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const name = ctx.param("name") orelse "stranger";
    try ctx.json(.{ .message = "hello", .name = name });
}

pub fn main(init: std.process.Init) !void {
    var backend = try netz.runtime.Backend.init(init.gpa);
    defer backend.deinit();
    const io = backend.io();

    var server = try weft.Server(App).init(
        io,
        init.gpa,
        .{ .address = .{ .ip4 = .loopback(8080) } },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/", home, .{});
    try router.get("/hello/:name", hello, .{ .middleware = &.{
        weft.handler(weft.middleware.requestId),
        weft.handler(weft.middleware.serverHeader),
    } });

    try server.serve();
}
```

## Middleware

A middleware is a plain function that calls `ctx.next()` to continue:

```zig
fn auth(ctx: *weft.Ctx) anyerror!void {
    if (ctx.header("authorization") == null) {
        ctx.setStatus(401);
        return ctx.text("Unauthorized");
    }
    try ctx.next();
}
```

Parameterized middleware uses a user-owned context:

```zig
var auth = weft.middleware.BasicAuth{
    .username = "admin",
    .password = "secret",
};
try router.get("/admin", admin, .{ .middleware = &.{auth.handler()} });
```

`next()` may be called at most once per handler invocation. Not calling it
short-circuits the chain. A response written before `next()` is preserved.

## Router

- Static segments are more specific than `:param`, which is more specific than
  the trailing `*` wildcard.
- `:param` captures one segment; `*` captures the remaining path.
- `router.any(...)` matches every method.
- Route middleware runs in registration order.

## Limits

`weft.Limits` maps Netz's HTTP/1 limits and adds weft-owned budgets:

- `max_request_arena_bytes` bounds per-request headers, bodies, params, and
  middleware locals.
- `max_response_bytes` rejects oversized responses before they are written.
- `max_connections` bounds concurrent connections through the worker count.
- `max_requests_per_connection` bounds persistent HTTP/1 reuse.

## Lifecycle

`Server.deinit` must not run while `serve` is active. The normal order is:

1. run `serve` in a task or thread;
2. call `server.stop()`;
3. await the serving task;
4. call `server.deinit()`.

`stop()` cancels pending accepts. An in-flight request may be interrupted by
cancellation; fully graceful drain is a future slice.

## Build and test

```sh
zig build
zig build test
zig build run-hello
```

## Status

The first slice targets HTTP/1.1 through `netz.http1.runtime`. The public
`Ctx`/`Handler`/`Router` surface is protocol-version agnostic so an HTTP/2 or
HTTP/3 adapter can be added without changing application handlers.
