# weft

`weft` is the application weaving layer on top of [`netz`](../netz): routing,
middleware, typed request locals, decoded request data, and bounded HTTP/1,
HTTP/2, and HTTP/3 server adapters for Zig 0.16.

The split is deliberate:

- **netz** owns protocol codecs, connection state machines, and HTTP framing.
- **weft** owns application dispatch: concrete `Ctx`, `Handler`, `Router`,
  middleware, and per-request budgets.
- **`std.Io`** is the runtime seam. `zio` can back it today; another `std.Io`
  implementation can replace it without changing protocol or application code.

`weft.netz` re-exports the protocol module for advanced transport
configuration. Public signatures use a small set of netz types (`Header`,
`Method`, `TlsListenOptions`, `WriteStrategy`, and WebSocket frames); these are
the supported escape hatches and follow the pinned netz version. zio and
operating-system types are not part of the public surface.

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
    const executors: u8 = @intCast(@min(
        std.Thread.getCpuCount() catch 1,
        8,
    ));
    var backend = try netz.runtime.Backend.initWithExecutors(
        init.gpa,
        executors,
    );
    defer backend.deinit();
    const io = backend.io();

    const common = [_]weft.Handler{
        weft.handler(weft.middleware.requestId),
        weft.handler(weft.middleware.serverHeader),
        weft.handler(weft.middleware.securityHeaders),
        weft.handler(weft.middleware.log),
    };

    // `init` stores the application context by value. Share mutable state
    // through pointers so handlers and pre-built middleware observe the same
    // instance (for example `App{ .metrics = &metrics_state }`).
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

Response bodies set with `ctx.text`, `ctx.setBody`, or `Response.setBody` are
borrowed slices: pass a literal or arena memory (for example
`ctx.arena.dupe(u8, bytes)`), not a stack buffer. `ctx.json` owns its
allocation.

## What you get

- **Request API** — percent-decoded path captures and query values, repeated
  header access, cookies, typed locals, request deadlines, client/TLS
  metadata, and bounded body helpers (`bodyJson`, `bodyForm`, `multipart`,
  `decodedBody`). See [docs/guide/request.md](docs/guide/request.md).
- **Streaming** — buffered or incremental request bodies, streamed responses,
  server-sent events, response trailers, and bounded multipart streaming on
  HTTP/1, HTTP/2, and HTTP/3.
- **Routing** — a segment trie with static > `:param` > `*` precedence,
  groups, automatic `OPTIONS`, `405` with `Allow`, and `HEAD` fallback. See
  [docs/guide/routing.md](docs/guide/routing.md).
- **Middleware** — request id, server header, access logging, security
  headers, Basic auth, CORS, recovery, compression (gzip/deflate/Brotli/zstd),
  ETag, Alt-Svc, Prometheus metrics, and bounded per-key rate limiting. See
  [docs/guide/middleware.md](docs/guide/middleware.md).
- **Adapters** — HTTP/1.1 cleartext, TLS, Unix sockets, h2c, TLS/ALPN `h2`,
  QUIC/TLS HTTP/3, and WebSocket upgrades over HTTP/1.1 and HTTP/2/HTTP/3
  extended CONNECT. A TLS listener can negotiate `h2` and `http/1.1` on one
  port, and the cleartext HTTP/2 listener can accept `Upgrade: h2c`. All share
  the same `Router`, `Ctx`, middleware, and limits. See
  [docs/guide/adapters.md](docs/guide/adapters.md).
- **Static files** — validators, RFC 9110 preconditions, single and multipart
  ranges, index files, MIME detection, traversal-safe paths, and
  precompressed `.br`/`.zst`/`.gz` sidecars. See
  [docs/guide/static-files.md](docs/guide/static-files.md).
- **OpenAPI and MCP** — OpenAPI 3.1 documents rendered from route metadata,
  and a Model Context Protocol server over Streamable HTTP. See
  [docs/guide/openapi-mcp.md](docs/guide/openapi-mcp.md).
- **Authentication** — bounded in-memory or file-backed sessions, session-bound
  CSRF protection (header or form token), HS256/EdDSA JWT signing, RS256/ES256
  and JWKS verification, and Bearer-token middleware. See
  [docs/guide/auth.md](docs/guide/auth.md).
- **Caching and cookies** — bounded response cache, HMAC-signed cookie values,
  and CSP nonce rendering. See
  [docs/guide/middleware.md](docs/guide/middleware.md).
- **TLS identity reload** — atomically replace the server certificate without
  rebinding the listener. See
  [docs/guide/adapters.md](docs/guide/adapters.md).
- **WebTransport and gRPC** — WebTransport sessions with datagrams and
  streams over QUIC/HTTP/3, and unary gRPC services over h2c or TLS/ALPN
  `h2`. See
  [docs/guide/webtransport-grpc.md](docs/guide/webtransport-grpc.md).
- **Budgets and lifecycle** — every request, response, middleware chain,
  multipart count, query count, and connection count is bounded by `Limits`;
  shutdown is cooperative and drain-bounded. See
  [docs/guide/limits-lifecycle.md](docs/guide/limits-lifecycle.md).

## Build and test

```sh
zig build
zig build test
zig build test-package
zig build check
zig build examples
zig build run-hello
zig build run-upload
zig build run-agent
zig build run-logging
zig build bench -Doptimize=ReleaseFast
zig build bench-server -Doptimize=ReleaseFast
zig build bench-middleware -Doptimize=ReleaseFast
zig build bench-accept -Doptimize=ReleaseFast
zig build bench-static -Doptimize=ReleaseFast
zig build bench-h2 -Doptimize=ReleaseFast
zig build bench-h3 -Doptimize=ReleaseFast
zig build bench-logging -Doptimize=ReleaseFast
zig build build-hello-server -Doptimize=ReleaseFast
zig build build-h2-hello-server -Doptimize=ReleaseFast
zig build build-h3-bench -Doptimize=ReleaseFast
```

`zig build` forwards `-Dscheduling` (`single_executor`, `pinned`, or
`work_stealing`) and `-Dzio-backend` (`poll`, `linux`, `epoll`, `kqueue`,
`io_uring`, or `iocp`) to netz. `-Dtest-filter=<substring>` narrows the test
run. Benchmark results, tuning conclusions, and the measurement metadata
convention live in [docs/performance.md](docs/performance.md).

## Status

HTTP/1.1 is served through `netz.http1.runtime` with cleartext, TLS, and
Unix-domain socket listeners. HTTP/1.0 and other request versions are rejected
by Netz with `400 Bad Request`. `Http2Server` and `Http3Server` provide h2c,
TLS/ALPN h2, and QUIC/TLS HTTP/3 adapters over the same application surface.
HTTP/1, HTTP/2, and HTTP/3 request bodies all stream incrementally.

Routes can carry OpenAPI 3.1 metadata that `weft.openapi.Document` renders and
serves, and `weft.mcp.Server` exposes tools, resources, and prompts over the
MCP Streamable HTTP transport from the same router.

Parser totality tests feed deterministic random bytes to the query, `Accept`,
buffered/streaming multipart, and HTTP-date/precondition parsers, asserting
that every input either fails cleanly or yields bounded, control-byte-free
results.

HTTP/1 protocol-error responses (`400/408/413/414/431`) are written through
`Connection.respondAndClose`, which permits one final response after a failed
request read, then half-closes and drains unread input within a 250 ms budget
so the status is not lost to a TCP RST.

## Limitations

- HTTP/2 batch throughput is close to axum in external single-connection
  comparisons. See [docs/performance.md](docs/performance.md) for the current
  numbers and the remaining tail-latency work.
- HTTP/1 p99/p999 tail latency depends on the zio executor count; closing the
  last gap needs zio-level wake and scheduling work.
- HTTP/3 sequential latency is higher than HTTP/2; QUIC framing and recovery
  dominate.
- `CONNECT` requests (HTTP/1 authority-form, HTTP/2/3 tunnel or extended
  CONNECT) receive `501`; weft exposes no tunnel writer.
- Handlers cannot be preempted while running CPU-bound code without reaching a
  cancellation point.
- WebSocket upgrades work on HTTP/1.1 and HTTP/2/HTTP/3 extended CONNECT.
  Extended CONNECT requires the peer to advertise
  `SETTINGS_ENABLE_CONNECT_PROTOCOL`; `permessage-deflate` is not negotiated on
  the extended CONNECT paths.
- `Etag` hashes buffered responses. Streamed responses are hashed only when
  `Etag.max_stream_bytes` opts in and the producer declares a known length
  within that cap.
- `StaticFiles` sidecar (`.br`/`.zst`/`.gz`) responses are not range-addressable
  by design; `Range` requests receive the raw file.

## Documentation

- [docs/README.md](docs/README.md) — documentation index (living guides and
  historical snapshots).
- [docs/architecture.md](docs/architecture.md) — layers, module map, request
  lifecycle, and ownership rules.
- [docs/api.md](docs/api.md) — public API surface exported by `weft`.
- [docs/guide/](docs/guide/) — request handling, adapters, routing,
  middleware, static files, OpenAPI/MCP, limits and lifecycle.
- [docs/performance.md](docs/performance.md) — curated benchmark results.
- [docs/performance-journal.md](docs/performance-journal.md) — append-only
  measurements and rejected experiments.
- [docs/logging.md](docs/logging.md) — kron integration and measured producer
  cost.
- [docs/validation/](docs/validation/) — dated historical validation
  snapshots.
- [docs/optimization-backlog.md](docs/optimization-backlog.md) — pending
  structure, documentation, and build work.
- [CHANGELOG.md](CHANGELOG.md) — user-visible changes.
