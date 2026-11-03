# weft

`weft` is the application weaving layer on top of [`netz`](../netz): routing,
middleware, typed request locals, decoded request data, and a bounded HTTP/1
server adapter for Zig 0.16.

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
    try ctx.json(.{
        .message = "hello",
        .name = name,
        .lang = ctx.queryParam("lang") orelse "en",
    });
}

fn health(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.json(.{ .status = "ok" });
}

pub fn main(init: std.process.Init) !void {
    var backend = try netz.runtime.Backend.init(init.gpa);
    defer backend.deinit();
    const io = backend.io();

    const common = [_]weft.Handler{
        weft.handler(weft.middleware.requestId),
        weft.handler(weft.middleware.serverHeader),
        weft.handler(weft.middleware.securityHeaders),
        weft.handler(weft.middleware.log),
    };

    var server = try weft.Server(App).init(
        io,
        init.gpa,
        .{
            .address = .{ .ip4 = .loopback(8080) },
            .middleware = &common,
        },
        .{},
    );
    defer server.deinit();

    var router = server.router();
    try router.get("/", home, .{});
    try router.get("/hello/:name", hello, .{});

    // Groups share a prefix and middleware.
    var api = try router.group("/api", .{});
    try api.get("/health", health, .{});

    try server.serve();
}
```

## Request API

`Ctx` is a concrete request context; handlers never see protocol framing types.

- `ctx.param(name)` returns a **percent-decoded** path capture.
- `ctx.queryParam(name)` returns the first **percent-decoded** query value.
  `+` is decoded as a space. `ctx.queryPairs()` exposes all pairs in wire order.
- `ctx.header(name)`, `ctx.body()`, `ctx.method()`, and `ctx.target()` expose the
  parsed request.
- `ctx.bodyJson(T)` parses JSON with the request arena.
- `ctx.bodyForm()` parses `application/x-www-form-urlencoded` bodies.
- `ctx.cookie(name)` reads request cookies; `ctx.setCookie(...)` appends a
  validated `Set-Cookie` field.
- `ctx.set(T, value)` / `ctx.get(T)` provide typed request locals. Keys are
  type-based, and values live in the request arena.

Malformed percent escapes and decoded control bytes are rejected with `400`
before a handler runs.

## Streaming

`ctx.stream(...)` selects an incremental body producer. The producer runs after
the handler returns and sees only a concrete `StreamWriter`:

```zig
fn producer(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
    try writer.write("hello ");
    try writer.write("stream");
}

fn streamed(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.setHeader("Content-Type", "text/plain; charset=utf-8");
    try ctx.stream(.{ .write_fn = producer, .length = 12 });
}
```

- A known `length` uses fixed framing; `null` uses chunked framing on HTTP/1.1.
- `Limits.max_response_bytes` bounds the producer even when the length is
  unknown.
- `HEAD`, `204`, `304`, and `1xx` responses discard the producer without running
  it.
- `cancel_fn` releases producer resources if the response is discarded before
  the producer starts.
- A producer that starts owns its resources and must release them on success or
  error.

## Static files

`weft.StaticFiles` is a route handler that streams files below a directory. It
supports ETag/`If-None-Match`, single `Range` requests (`206`/`416`), `HEAD`,
index files, MIME detection, dotfile rejection, and traversal-safe path
normalization.

```zig
var files = weft.StaticFiles{
    .dir = try std.Io.Dir.cwd().openDir(io, "public", .{}),
    .max_file_bytes = 8 * 1024 * 1024,
};

try router.addRaw(.GET, "/assets/*", files.handler(), .{});
```

`follow_symlinks` defaults to `false`; the handler checks the path with
`statFile(.follow_symlinks = false)` and rejects non-regular entries. Files
larger than `max_file_bytes` or `Limits.max_response_bytes` return `413`.

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

`next()` may be called at most once per handler invocation. Not calling it
short-circuits the chain. A response written before `next()` is preserved.

Middleware runs in this order:

1. server-level `Options.middleware` (including for `404`, `405`, and automatic
   `OPTIONS`);
2. group middleware, outer group first;
3. route middleware in registration order;
4. the route handler.

Built-ins:

- `requestId` — preserves a validated incoming `X-Request-Id` or generates a
  128-bit hex id, and always echoes it in the response.
- `serverHeader` — adds `Server` unless already set.
- `log` — logs method, target, request id, status, and elapsed nanoseconds.
- `securityHeaders` / `SecurityHeaders` — configurable browser hardening fields.
- `BasicAuth` — constant-time Basic credential check with a challenge response.
- `Cors` — exact-origin allow list, credential support, preflight handling, and
  `Vary` maintenance.
- `Compress` — gzip for accepted `Accept-Encoding`, compressible content types,
  and bodies above `min_bytes`; existing `Content-Encoding` is respected.
- `recover` — converts an uncommitted handler failure into `500`, or marks a
  committed partial response `Connection: close`.

Parameterized middleware uses a user-owned context:

```zig
var auth = weft.middleware.BasicAuth{
    .username = "admin",
    .password = "secret",
};
try router.get("/admin", admin, .{ .middleware = &.{auth.handler()} });
```

## Router

- Routes are indexed by a segment trie, so lookup cost scales with path depth
  rather than the number of registered routes.
- At each segment, a static child wins over `:param`, which wins over the
  trailing `*` wildcard. Precedence is decided at the leftmost differing
  segment, independent of registration order.
- `:param` captures one segment; `*` captures the remaining path.
- `router.any(...)` matches every method.
- `HEAD` falls back to a `GET` route when no explicit `HEAD` route exists.
- A path that exists for other methods returns `405` with an `Allow` field.
- `OPTIONS` is answered automatically with `204` and `Allow` when no explicit
  `OPTIONS` route exists.
- `router.group(prefix, options)` shares a prefix and middleware; groups can
  nest.
- Invalid patterns, duplicate method/path pairs, and wildcard/`any` conflicts
  are rejected at registration time.
- Path depth, captures per route, allowed methods, and middleware length are
  all bounded.

## Limits

`weft.Limits` maps Netz's HTTP/1 limits and adds weft-owned budgets:

- `max_request_arena_bytes` bounds per-request headers, bodies, params,
  decoded query values, response headers, and middleware locals.
- `max_response_bytes` rejects oversized buffered bodies before they are
  written and bounds the bytes produced by streaming bodies.
- `max_response_headers` and `max_response_head_bytes` bound the response head
  independently of the body. Weft reserves head room for `Content-Length`,
  `Date`, and `Connection` fields that Netz may add, so the configured budget
  describes the complete wire head. Header names and values are validated and
  copied into the response arena; CR/LF injection is rejected.
- `max_middleware` bounds the combined server/group/route middleware chain.
- `max_query_params` bounds decoded query pairs.
- `max_connections` bounds concurrent connections through the worker count.
- `max_requests_per_connection` bounds persistent HTTP/1 reuse.

## Lifecycle

`Server.deinit` must not run while `serve` is active. The normal order is:

1. run `serve` in a task or thread;
2. call `server.stop()`;
3. await the serving task;
4. call `server.deinit()`.

`stop()` is cooperative: idle workers stop accepting within
`accept_poll_interval`, in-flight requests finish, and subsequent responses
carry `Connection: close`. `serve` waits for workers to drain before returning.
A connection blocked waiting for a subsequent keep-alive request is bounded by
`request_head_timeout` (30 seconds by default). A handler that never returns
still holds its worker; fully preemptive cancellation is not part of this slice.

Register routes before calling `serve`. Matching is read-only, but registration
itself is not synchronized with in-flight requests.

## Build and test

```sh
zig build
zig build test
zig build run-hello
zig build bench -Doptimize=ReleaseFast
```

The router benchmark registers 1024 static routes and 256 parameter routes.
On the reference development host, a ReleaseFast run reports roughly 80 ns per
static lookup and 90 ns per parameter lookup (about 12.4M and 11.1M lookups per
second), including capture allocation from a fixed arena.

## Status

The first slice targets HTTP/1.1 through `netz.http1.runtime`, and mirrors
HTTP/1.0 request versions with appropriate connection semantics. The public
`Ctx`/`Handler`/`Router` surface is protocol-version agnostic so an HTTP/2,
HTTP/3, or TLS adapter can be added without changing application handlers.
Remaining slices include multi-range and multi-encoding responses, preemptive
request deadlines, and TLS/HTTP2/HTTP3 adapters.
