# Request handling

Request parsing, typed accessors, body helpers, streaming responses, and
incremental request bodies.

[Back to the documentation index](../README.md)

## Request API

`Ctx` is a concrete request context; handlers never see protocol framing types.

- `ctx.param(name)` returns a **percent-decoded** path capture.
- `ctx.queryParam(name)` returns the first **percent-decoded** query value.
  `+` is decoded as a space. `ctx.queryPairs()` exposes all pairs in wire order.
Plain queries borrow the request target and allocate only the pair array;
escaped queries decode into a single buffer.
- `ctx.header(name)`, `ctx.body()`, `ctx.method()`, and `ctx.target()` expose the
  parsed request. `ctx.body()` returns the buffered body on HTTP/1, HTTP/3, and
  HTTP/2 routes whose request declared a non-zero `Content-Length`; for an
  HTTP/2 body without a declared length, use `ctx.readBody()`. After
  `readBody()` has drained a streaming body, `ctx.body()` returns the cached
  bytes. `ctx.headers()` and `ctx.headerValues(name)` expose repeated
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
- `ctx.sendEarlyHints(headers)` writes an interim `103 Early Hints` response
  before the final response on HTTP/1.1, HTTP/2, and buffered HTTP/3
  responses. A streamed HTTP/3 response cannot combine early hints with an
  already-started stream and returns `500`.

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

