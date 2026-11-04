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

## Request API

`Ctx` is a concrete request context; handlers never see protocol framing types.

- `ctx.param(name)` returns a **percent-decoded** path capture.
- `ctx.queryParam(name)` returns the first **percent-decoded** query value.
  `+` is decoded as a space. `ctx.queryPairs()` exposes all pairs in wire order.
Plain queries borrow the request target and allocate only the pair array;
escaped queries decode into a single buffer.
- `ctx.header(name)`, `ctx.body()`, `ctx.method()`, and `ctx.target()` expose the
  parsed request. `ctx.headers()` and `ctx.headerValues(name)` expose repeated
  fields; `ctx.trailers()` and `ctx.trailer(name)` expose request trailers for
  every adapter: HTTP/1 buffered and streaming (after the body is consumed),
  buffered HTTP/2/HTTP/3, and streaming HTTP/2/HTTP/3. Field bytes are copied
  into the request arena, so a trailer stays valid for the rest of the request.
- `ctx.accepts(media_type)` and `ctx.preferredType(candidates)` implement
  `Accept` negotiation (wildcards, q-values, and the most-specific-range rule,
  so `text/*;q=0, */*;q=1` still rejects `text/html`).
- Malformed or oversized request heads map to `400`, `431`, `414`, `413`, or
  `408` before any handler runs.
- `ctx.protocol()`, `ctx.clientAddress()`, `ctx.isTls()`, and
  `ctx.peerCertificates()` expose adapter metadata such as HTTP version, peer
  address, transport security, and the verified mTLS client chain (leaf
  first). With
  `Limits.trust_forwarded_for`, the leftmost `X-Forwarded-For` entry replaces
  the peer address; enable it only behind a proxy that sanitizes the header.
- `ctx.deadline()`, `ctx.remaining()`, and `ctx.expired()` expose the
  `Limits.request_timeout` budget for cooperative handlers.
- `ctx.decodedBody()` applies request `Content-Encoding` layers (gzip,
  deflate, br, zstd) with `Limits.max_body_bytes` as the decoded bound.
  `ctx.decodedReader()` exposes the same decoding incrementally on streaming
  routes, with both encoded and decoded bytes bounded; a package test feeds a
  20 KiB gzip body through a 4 KiB streaming window to exercise multi-chunk
  decoding. After `decodedReader()` starts, `ctx.readBody()` continues the
  decoded stream instead of the raw one.
- `ctx.addTrailer(name, value)` appends a response trailer. HTTP/1 emits
  trailers only when the request sent `TE: trailers`; HTTP/2 and HTTP/3 emit
  them after the body.
- `ctx.bodyJson(T)` parses decoded JSON with the request arena. The request
  must declare `application/json` or a structured `+json` type
  (`application/problem+json`, including parameters); other media types
  become `415`. Invalid JSON becomes `400`; an unsupported coding becomes
  `415`; an oversized decoded body becomes `413`.
- `ctx.bodyForm()` parses decoded `application/x-www-form-urlencoded` bodies.
- `ctx.multipart()` parses `multipart/form-data` with bounded part and header
  counts; part data borrows the bounded request body, and boundaries are
  matched only at line starts so field data containing boundary text is safe.
  Filenames honor RFC 5987 `filename*` (UTF-8 and ISO-8859-1, widened to
  UTF-8) and prefer it over the plain `filename` fallback.
- `ctx.multipartStream()` parses `multipart/form-data` incrementally from a
  streaming route on HTTP/1, HTTP/2, and HTTP/3. It keeps one fixed window
  (`min(max_streaming_window_bytes, max_request_arena_bytes / 2)`), yields one
  part at a time with a `DataReader` (`next` or bounded `readAll`), and
  enforces `Limits.max_body_bytes` across the whole body, so large uploads
  never need to fit in the request arena. Stopping a part early is safe:
  `nextPart` skips the remainder. `Content-Encoding`'d bodies are decoded
  incrementally before parsing.
- `ctx.cookie(name)` reads request cookies, unwrapping RFC 6265 DQUOTE
  values; `ctx.setCookie(...)` appends a validated `Set-Cookie` field.
  `SameSite=None` and `Partitioned` require `Secure`, and the `__Secure-` /
  `__Host-` prefixes are enforced (the latter also needs `Path=/` and no
  `Domain`). Multiple `Set-Cookie` fields are preserved on all three adapters.
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

`ctx.sse(...)` selects a `text/event-stream` body. It defaults `Content-Type`,
`Cache-Control: no-cache`, and `X-Accel-Buffering: no` when the handler has not
set them, and the compression middleware leaves event streams uncompressed:

```zig
fn events(_: ?*anyopaque, writer: *weft.StreamWriter) anyerror!void {
    try weft.sse.write(writer, .{
        .id = "1",
        .event = "tick",
        .data = "first\nsecond",
    });
}

fn eventsRoute(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.sse(.{ .write_fn = events });
}
```

`sse.write` emits `id`, `event`, `retry`, and one `data:` line per payload
line; `sse.comment` writes a heartbeat comment. Field values containing CR, LF,
or NUL are rejected.

### Streaming request bodies

Register an HTTP/1 route with `.streaming = true` to receive the request body
incrementally:

```zig
fn upload(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    const reader = ctx.bodyReader().?;
    var total: usize = 0;
    while (try reader.next()) |chunk| total += chunk.len;
    try ctx.json(.{ .bytes = total });
}

try router.post("/upload", upload, .{ .streaming = true });
```

- HTTP/1 handlers pull directly from netz's bounded `RequestBodyReader`.
- HTTP/2 handlers pull DATA through netz's `ServerDuplexStream.nextBody()`.
- HTTP/3 handlers pull DATA through
  `HandshakeServerSession.ConcurrentStream.nextBody()`; netz keeps only a
  bounded resident window per stream.
- `ctx.bodyReader()` returns a concrete `weft.BodyReader`; `ctx.readBody()`
  drains the whole body into the request arena when incremental access is not
  needed.
- Bytes the handler does not read are drained before the response is written,
  keeping the connection reusable.
- `RouteOptions.max_body_bytes` sets a per-route body budget below the server
  limit. A buffered body above it is rejected with `413` before the handler
  runs; streaming reads return `413` through `Ctx.bodyReader()` and
  `Ctx.readBody()`.
- `RouteOptions.timeout` overrides `Limits.request_timeout` for one route.
  The route budget drives both the `Ctx.deadline()` value and the `503`
  cancellation race.

## TLS

Set `Options.tls` to a `netz.http1.runtime.TlsListenOptions` to serve HTTPS.
Weft applies its own `Limits` and `tcp_nodelay` to the nested TLS options, so
HTTP and TLS budgets stay consistent:

```zig
var server = try weft.Server(App).init(
    io,
    gpa,
    .{
        .address = .{ .ip4 = .loopback(443) },
        .tls = .{ .identity = identity },
    },
    .{},
);
```

TLS workers use `tls_accept_timeout` as the combined accept plus handshake
budget, which also bounds idle shutdown polling. TLS transport, ciphers,
certificate policy, and session handling remain owned by Netz.

## Unix sockets

Set `Options.unix_path` instead of `Options.address` to serve HTTP/1 over a
Unix-domain stream socket (for example behind a reverse proxy on the same
host). Exactly one of the two must be set, and TLS is rejected on Unix
sockets:

```zig
var server = try weft.Server(App).init(
    io,
    gpa,
    .{ .unix_path = "/run/weft.sock" },
    .{},
);
defer server.deinit();
```

The application surface is unchanged: routing, middleware, streaming, and
limits behave exactly as on TCP. `ctx.clientAddress()` is `null` because a
Unix socket has no IP peer (std otherwise reports a synthetic `127.0.0.1`);
with `Limits.trust_forwarded_for`, a trusted `X-Forwarded-For` header still
supplies the client address. `server.ipAddress()` returns `null` and
`server.unixPath()` returns the configured path; `server.address()` panics for
a Unix-socket server because there is no TCP address. The socket file is
caller-owned: Netz closes the listener on `deinit` but does not unlink the
path, so remove it after the server stops.

## HTTP/2

`weft.Http2Server(H)` serves cleartext prior-knowledge h2c and optional TLS
with mandatory ALPN `h2`. It reuses the same `Router`, `Ctx`, middleware,
limits, and streaming response contract:

```zig
var server = try weft.Http2Server(App).init(
    io,
    gpa,
    .{
        .address = .{ .ip4 = .loopback(8080) },
        .limits = .{ .max_body_bytes = 1024 * 1024 },
    },
    .{},
);
defer server.deinit();

try server.router().get("/hello/:name", hello, .{});
try server.serve();
```

For HTTPS, set `Options.tls` to a `netz.http2.runtime.TlsListenOptions`; Netz
requires ALPN `h2`, and weft applies its own `Limits` and `tcp_nodelay`.
`tls_accept_timeout` bounds accept, TLS setup, and the HTTP/2 bootstrap.

Set `Options.unix_path` instead of `Options.address` to serve prior-knowledge
h2c over a Unix-domain socket, with the same exclusivity and TLS rules as the
HTTP/1 adapter. `ctx.clientAddress()` is `null` on that transport, and
`ipAddress()` / `unixPath()` report which transport is active.

Netz owns frame parsing, HPACK, flow control, and stream state. Weft maps each
completed request into the concrete `Ctx` view and maps responses back to
lowercase HTTP/2 header fields. Response streaming, `HEAD`, `404/405/OPTIONS`,
request decoding, and timeout budgets behave the same as HTTP/1.

Netz's concurrent engine owns the frame reader, HPACK state, and socket
writer. Every request runs in one of up to `max_concurrent_handlers` handler
tasks; handlers pull request DATA from bounded per-stream buffers and may
submit buffered or chunked responses with trailers. Advertised stream
concurrency is capped to the same handler bound.

## HTTP/3

`weft.Http3Server(H)` serves HTTP/3 over QUIC/TLS with ALPN `h3`. It reuses the
same `Router`, `Ctx`, middleware, limits, decoded inputs, and streaming
response contract:

```zig
var server = try weft.Http3Server(App).init(
    io,
    gpa,
    .{
        .address = .{ .ip4 = .loopback(8443) },
        .handshake = .{
            .identity = identity,
            .local_connection_id = "weft-h3",
        },
    },
    .{},
);
defer server.deinit();

try server.router().get("/hello/:name", hello, .{});
try server.serve();
```

Netz owns QUIC handshake, TLS, stream parsing, QPACK, flow control, and
recovery. Weft maps each completed request into `Ctx` and maps responses back
to lowercase HTTP/3 fields. `quic_limits`, `max_concurrent_streams`,
`max_concurrent_handlers`, and `accept_timeout` bound transport, admission, and
handler concurrency.

Each session runs up to `max_concurrent_handlers` handler tasks concurrently
through netz's owner-serialized concurrent engine. Handlers pull request DATA
incrementally with `Ctx.bodyReader()` (`.h3_stream`) while netz bounds the
resident per-stream window with `max_streaming_window_bytes` and enforces
`max_body_bytes` on the whole body. The advertised request-stream concurrency
is capped to `min(max_concurrent_streams, max_concurrent_handlers)`.

## WebSockets

`ctx.upgradeWebSocket(...)` selects an RFC 6455 session on HTTP/1.1. Weft
validates the opening handshake, writes `101 Switching Protocols`, and runs the
session synchronously on the connection worker:

```zig
fn wsEcho(_: ?*anyopaque, session: *weft.WebSocketSession) anyerror!void {
    var message = try session.receiveMessage();
    defer session.deinitMessage(&message);
    try session.sendText(message.payload);
}

fn ws(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.upgradeWebSocket(.{ .run_fn = wsEcho });
}
```

The session exposes text/binary sends, ping/pong control frames,
frame/message reads with `deinitMessage`, and explicit `sendClose(code, reason)`.
`close()` sends a normal closure frame when one has not already been written
and then releases the transport. An optional `subprotocol` must be offered by
the client. Set `.compression = true` to negotiate RFC 7692
`permessage-deflate`; the accepted parameters are echoed in
`Sec-WebSocket-Extensions` and messages at or above
`compression_threshold` bytes (default 32) are compressed. HTTP/2 and HTTP/3
reject WebSocket upgrades with `400`.

## Static files

`weft.StaticFiles` is a route handler that streams files below a directory. It
supports `ETag`/`Last-Modified` validators, RFC 9110 preconditions
(`If-Match`, `If-None-Match`, `If-Modified-Since`, `If-Unmodified-Since`),
`If-Range` with either an ETag or an HTTP-date, single and multipart `Range`
requests (`206`/`416`), `HEAD`, index files, MIME detection, dotfile rejection,
and traversal-safe path normalization.

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
Directory requests without a trailing slash return `301` to the slash form,
preserving the query string, so relative links in the index document resolve
correctly; set `.redirect_directories = false` to serve the index in place.
Set `.download = true` to emit `Content-Disposition: attachment` with the
served basename; non-ASCII names also carry an RFC 5987 `filename*` value.

With `precompressed` enabled (the default), sibling `.br`, `.zst`, and `.gz`
sidecars are served according to `Accept-Encoding` (`br` preferred, then
`zstd`, then `gzip`, honouring `q` weights and `*`). The response keeps the
original `Content-Type`, adds `Content-Encoding` and `Vary: Accept-Encoding`,
and reports the sidecar's `Content-Length`/`ETag`. Sidecars older than the
source file are ignored by default; set `.check_sidecar_freshness = false` to
serve them anyway. Encoded representations are not range-addressable: a
request carrying `Range` always receives the raw file with
`Accept-Ranges: bytes`. Set `.precompressed = false` to disable sidecars.

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
- `log` / `Log` — logs method, target, protocol, remote address, request id,
  status, and elapsed nanoseconds. Handler failures report the status dispatch
  will emit, and client cancellations log as `499`. `Log{ .format = .json }`
  emits one compact JSON object per request with JSON-escaped values.
- `securityHeaders` / `SecurityHeaders` — configurable browser hardening fields.
- `BasicAuth` — constant-time Basic credential check with a challenge response.
- `Cors` — exact-origin allow list, credential support, preflight handling,
  configured request-header validation, and `Vary: Origin` on every response
  (including rejected and origin-less requests); preflights also vary on
  `Access-Control-Request-Method`/`-Headers`.
- `Compress` — gzip, deflate, Brotli, and zstd negotiation from
  `Accept-Encoding` quality values (malformed or out-of-range `q` values are
  treated as unacceptable), compressible content types, and bodies above
  `min_bytes`; streamed bodies use concatenated gzip members or continuous
  deflate/Brotli/zstd encoder state, depending on the negotiated coding.
  Existing `Content-Encoding`, `no-transform`, and refused identity are
  respected.
- `recover` — converts an uncommitted handler failure into the status dispatch
  would emit (`400`/`413`/`415`/`500`), or marks a committed partial response
  `Connection: close`.
- `Etag` — content-derived `ETag` for buffered `200` responses, answering
  `If-None-Match` with `304`. Register it outside `Compress` so the tag covers
  the final encoded representation.
- `AltSvc` — advertises an HTTP/3 endpoint (`Alt-Svc: h3=":443"; ma=86400` by
  default) on HTTP/1.1 and HTTP/2 responses, and skips the header when the
  request already arrived over HTTP/3.
- `Metrics` — lock-free total, active, status-class, and latency counters with a
  `snapshot()` API for health or metrics endpoints. Handler errors are
  classified with the same status mapping dispatch uses, and canceled requests
  are excluded from status classes. `snapshot().writePrometheus(writer, name)`
  renders the Prometheus text format; the namespace is validated to prevent
  exposition injection.
- `RateLimit` — bounded per-client token buckets keyed by the peer IP address
  without the ephemeral port (IPv4-mapped IPv6 shares the IPv4 key), with `429`
  and `Retry-After`, fixed storage, and least-recently-seen eviction.
  `Options.key_header` keys buckets on a hashed request header instead (for
  example an API key), falling back to the peer address when it is absent.
  Reverse-proxy deployments must apply their own trusted-forwarded-address
  policy.

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
  `OPTIONS` route exists. `OPTIONS *` advertises methods supported across the
  router.
- `router.group(prefix, options)` shares a prefix and middleware; groups can
  nest.
- Invalid patterns, duplicate method/path pairs, and wildcard/`any` conflicts
  are rejected at registration time.
- `Options.not_found`, `Options.bad_request`, and
  `Options.method_not_allowed` replace the default fallback bodies. They can
  inspect `ctx.get(weft.RouteFailure)`; the default status and `Allow` fields
  are pre-set before they run.
- Path depth, captures per route, allowed methods, and middleware length are
  all bounded.

## Limits

`weft.Limits` maps Netz's HTTP/1 limits and adds weft-owned budgets:

- `max_request_arena_bytes` bounds per-request headers, bodies, params,
  decoded query values, response headers, and middleware locals. HTTP/1,
  HTTP/2, and HTTP/3 adapters all enforce it with a fixed arena.
- `max_response_bytes` rejects oversized buffered bodies before they are
  written and bounds the bytes produced by streaming bodies.
- `max_response_headers` and `max_response_head_bytes` bound the response head
  independently of the body. Weft reserves head room for `Content-Length`,
  `Date`, and `Connection` fields that Netz may add, so the configured budget
  describes the complete wire head. Header names and values are validated and
  copied into the response arena; CR/LF injection is rejected.
- `max_middleware` bounds the combined server/group/route middleware chain.
- `max_query_params` bounds decoded query pairs.
- `max_multipart_parts` bounds `multipart/form-data` parts.
- `max_streaming_window_bytes` bounds the copy window used to stream request
  bodies to a handler task; the protocol layer still enforces
  `max_body_bytes` on the total body.
- `max_http2_concurrent_streams` bounds simultaneously open HTTP/2 request
  streams per connection (default 16), limiting buffered DATA while a
  connection is processed serially.
- `max_http2_frame_payload` bounds the local HTTP/2 frame payload allocation
  ceiling (default 1 MiB).
- `request_timeout` optionally races the handler/middleware chain against a
  timer. On expiry the chain is canceled at its next cancellation point and the
  request returns `503`. CPU-bound handlers with no cancellation point cannot be
  preempted.
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
`Options.drain_timeout` bounds that wait; on expiry the worker group is
cancelled at its next cancellation point. A connection blocked waiting for a
subsequent keep-alive request is bounded by `request_head_timeout` (30 seconds
by default). A handler that never reaches a cancellation point still holds its
worker; fully preemptive cancellation is not part of this slice.

Register routes before calling `serve`. Matching is read-only, but registration
itself is not synchronized with in-flight requests.

## Build and test

```sh
zig build
zig build test
zig build run-hello
zig build run-upload
zig build bench -Doptimize=ReleaseFast
zig build bench-server -Doptimize=ReleaseFast
zig build bench-middleware -Doptimize=ReleaseFast
zig build bench-static -Doptimize=ReleaseFast
zig build bench-h2 -Doptimize=ReleaseFast
```

`run-upload` starts a server, drives one streaming upload, one streaming
multipart upload, an SSE response, and the Prometheus endpoint, then stops.

The router benchmark registers 1024 static routes and 256 parameter routes.
On the reference development host, ReleaseFast reports about 52–56 ns per
static lookup (about 18–19M lookups/s) and about 91 ns per parameter lookup
(about 11M lookups/s), including capture allocation from a fixed arena.
Capture-free routes skip the parameter allocation entirely.

`bench-static` measures the `StaticFiles` handler in-process (normalization,
stat, validators, and streamed reads) against a 64 KiB file and a 1 KiB file,
plus conditional and range responses:

```text
static large.bin:      6.7–10.4 µs/request, 96k–150k requests/s
static small.txt:      4.7–7.8 µs/request, 129k–213k requests/s
static conditional 304: 1.55 µs/request, ~643k requests/s
static range 1 KiB:    5.2–6.3 µs/request, 158k–193k requests/s
```

Host load moves the file-read numbers; the `304` validator path is stable
because it never opens the file.

`bench-middleware` measures the application-layer chain with a fixed arena and
no I/O, isolating weft's overhead from netz framing:

```text
middleware baseline (handler only):            75 ns/request
middleware requestId:                         196 ns/request
middleware Metrics:                           141 ns/request
middleware Etag:                              152 ns/request
middleware Compress:                           96 ns/request
middleware requestId+Metrics+Etag+Compress:   322 ns/request
```

`requestId` seeds a per-thread PRNG once and then generates ids without a
syscall, which cut its cost from ~505 ns to ~196 ns.

`bench-server` measures one keep-alive HTTP/1 client against a one-worker
server. On the reference host it reports roughly 9–16 µs per request (about
60k–111k requests/s) depending on host load; this includes Netz HTTP/1 framing
and runtime task wakeups, not just application dispatch. The latest quiet-host
run measured 9.0 µs (111k requests/s).

`bench-h2` measures one cleartext h2c connection: 100k sequential requests,
128k batched GETs, and 128k batched 2 KiB uploads, all in batches of 32
concurrent streams. With netz's pooled concurrent handlers, the reference host
reports roughly 26 µs per request (about 38k requests/s) sequentially, 15 µs
(about 67k requests/s) for batched GETs, and 19 µs (about 52k requests/s) for
batched uploads. HTTP/1 keep-alive on the same host is about 16 µs (~61k
requests/s); H2 batched GET throughput exceeds HTTP/1, while the sequential
path still pays HTTP/2 framing. `-Dh2-batch=<n>` and
`-Dh2-batch-iterations=<n>` override the shape.

`bench-h3` uses a synthetic QUIC handshake (no TLS): 10k sequential requests,
32k batched GETs, and 32k batched 2 KiB uploads, all in batches of 32 streams.
With the default 1 ms weft poll interval and netz's single-packet buffered
response emission (`e0d72d80`), it reports roughly 61 µs per request (about
16k requests/s) sequentially, 52 µs (~19k requests/s) for 32-stream batched
GETs, and 77 µs (~13k requests/s) for 32-stream batched uploads. `-Dh3-batch=8`
reports ~53 µs (~19k requests/s) for GETs and ~61 µs (~16k requests/s) for
uploads, so 32-stream batching is now within ~10–25% of the eight-stream path
instead of ~3× slower. `-Dh3-batch=8` raises batched
GET throughput to ~19k requests/s, indicating owner/worker contention above
about eight concurrent streams. A 5 ms poll interval measured ~10.1 ms/req
sequentially before these fixes, so the shorter default and the netz wake
changes are both important for H3 latency.

## Status

HTTP/1.1 is served through `netz.http1.runtime` with cleartext, TLS, and
Unix-domain socket listeners, and mirrors HTTP/1.0 request versions with
appropriate connection semantics. `Http2Server` and `Http3Server` provide
h2c, TLS/ALPN h2, and QUIC/TLS HTTP/3 adapters over the same application
surface. HTTP/1, HTTP/2, and HTTP/3 request bodies all stream incrementally.
HTTP/2 and HTTP/3 requests run up to `max_concurrent_handlers` handler tasks
concurrently through netz's owner-serialized stream engines.

Parser totality tests feed deterministic random bytes to the query, `Accept`,
buffered/streaming multipart, and HTTP-date/precondition parsers, asserting
that every input either fails cleanly or yields bounded, control-byte-free
results.

HTTP/1 protocol-error responses (`400/408/413/414/431`) are written through
`Connection.respondAndClose`, which permits one final response after a failed
request read, then half-closes and drains unread input within a 250 ms budget
so the status is not lost to a TCP RST.

## Limitations

- HTTP/3 sequential latency is higher than HTTP/2 (roughly 76 µs vs 25 µs per
  request on the reference host); QUIC framing and recovery dominate.
- Handlers cannot be preempted while running CPU-bound code without reaching a
  cancellation point.
- WebSocket upgrades are HTTP/1.1 only; HTTP/2 and HTTP/3 return `400`.
- `Etag` covers buffered responses; streamed bodies are not hashed.
- `StaticFiles` sidecar (`.br`/`.zst`/`.gz`) responses are not range-addressable
  by design; `Range` requests receive the raw file.
