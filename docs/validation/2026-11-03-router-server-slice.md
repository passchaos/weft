# Router and server hardening slice — 2026-11-03

## Scope

Move the application layer from a linear route scan and per-route-only
middleware to a method-aware segment trie with bounded request/response
processing, decoded request data, and cooperative graceful shutdown.

## Changes

- Router rewritten as a segment trie with leftmost static > parameter >
  wildcard precedence. Lookup cost now scales with path depth, not route count.
- Registration rejects invalid patterns, duplicate method/path pairs, wildcard
  or `any` conflicts, over-deep patterns, too many captures, and oversized
  middleware chains.
- `405 Method Not Allowed` with a bounded `Allow` field, automatic `OPTIONS`
  (`204` + `Allow`), and `HEAD` fallback to `GET`.
- Route groups with owned prefixes and middleware chains, including nesting.
- Decoded path parameters and query pairs; malformed percent encoding and
  control bytes become `400`.
- Typed JSON/form body helpers, cookie lookup (including DQUOTE unwrapping) and
  validated `Set-Cookie`
  serialization.
- `Ctx.trailers()` and `Ctx.trailer(name)` expose HTTP/1 chunked request
  trailers and buffered HTTP/2/HTTP/3 request trailers. HTTP/2 streaming routes
  expose trailers once the body has been consumed; HTTP/3 streaming routes are
  still buffered.
- Response header count/byte budgets, header-name/value validation, copying
  into the response arena, replace/append semantics, and head room reserved for
  Netz-added `Content-Length`, `Date`, and `Connection` fields.
- Server-level middleware runs for matched routes, `404`, `405`, `400`, and
  automatic `OPTIONS`.
- Cooperative shutdown: workers poll accepts, in-flight requests finish, idle
  keep-alive reads are bounded by `request_head_timeout`, and responses carry
  `Connection: close` once shutdown starts.
- HTTP/1.0 request versions are mirrored in responses with appropriate
  connection semantics.
- Middleware: request-id propagation/validation, request-id-aware logging,
  constant-time Basic auth, security headers, CORS with preflight, recovery, and
  bounded gzip compression.
- Recovery middleware maps uncommitted failures through the dispatcher's
  error-to-status table instead of collapsing every failure to `500`.
- Streaming response bodies through a concrete `StreamBody`/`StreamWriter` seam,
  with fixed or chunked framing, a `max_response_bytes` producer budget,
  HEAD/body-forbidden suppression, and cancellation cleanup.
- Streaming request bodies for HTTP/1 through netz's bounded pull reader and
  for HTTP/2 through `ServerDuplexStream.nextBody()`, both exposed as
  `Ctx.bodyReader()`. Unread bytes are drained before the response is written,
  and `Ctx.readBody()` buffers into the request arena.
- HTTP/3 exposes a one-chunk replay reader for streaming routes over its
  already-buffered DATA body.
- `Ctx.addTrailer` appends response trailers; HTTP/1 emits them only for
  requests with `TE: trailers`, while HTTP/2 and HTTP/3 send trailing HEADERS
  after the body.
- `Ctx.sse` plus `sse.write`/`sse.comment` helpers for `text/event-stream`
  responses, with multiline `data:` framing, `id`/`event`/`retry` fields,
  injection rejection, and compression opt-out.
- `StaticFiles` handler with traversal-safe normalization, dotfile/symlink
  policy, MIME detection, ETag/`Last-Modified`, single and multipart `Range`
  support (`206`/`416`), index files, and streamed file reads.
- Directory requests without a trailing slash redirect (`301`) to the slash
  form while preserving the query string; the empty wildcard capture maps to
  the configured root directory so `/assets/` serves its index.
- RFC 9110 precondition evaluation (`If-Match`, `If-None-Match`,
  `If-Modified-Since`, `If-Unmodified-Since`) in RFC order, plus `If-Range`
  ETag and HTTP-date forms. HTTP dates accept IMF-fixdate, RFC 850, and
  asctime inputs.
- `StaticFiles` can force downloads with `Content-Disposition: attachment`
  and an escaped basename.
- `StaticFiles` negotiates precompressed `.br`/`.zst`/`.gz` sidecars from
  `Accept-Encoding` (q-weighted, `br > zstd > gzip` on ties), preserves the
  original MIME type, emits `Content-Encoding`/`Vary: Accept-Encoding`, and
  falls back to the raw file for `Range` requests so byte offsets stay valid.
  Sidecars older than the source file are ignored by default.
- Request `Content-Encoding` decoding through `Ctx.decodedBody`, used by
  `bodyJson`/`bodyForm`; `bodyJson` requires `application/json` or a
  structured `+json` media type (parameters allowed), malformed JSON maps to
  `400`, unsupported media types and codings to `415`, and oversized decoded
  bodies to `413`.
- CORS preflight validates requested headers against a configured allow list,
  and every CORS response carries `Vary: Origin` so shared caches cannot reuse
  a non-CORS response for an allowed origin.
- Optional TLS listener through `Options.tls`, reusing Netz's TLS transport while
  applying weft HTTP limits and a bounded accept/handshake budget.
- Optional `Limits.request_timeout` races the middleware/handler chain against a
  timer, cancels at the next cancellation point, and returns `503`.
- Response compression negotiates gzip, deflate, Brotli, or zstd from
  `Accept-Encoding` quality values, honors `no-transform`, and returns `406`
  when identity is explicitly refused. Malformed or out-of-range `q` values
  are treated as unacceptable.
- Optional `Options.drain_timeout` bounds graceful worker drain and cancels the
  group cooperatively when the budget expires.
- `OPTIONS *` advertises router-wide methods, `Ctx` exposes repeated header
  iteration, and static `If-Range` falls back to a full response when the ETag
  no longer matches.
- Server options accept custom `404`, `400`, and `405` fallback handlers that
  can inspect `RouteFailure`; default status and `Allow` are pre-set.
- Streamed response bodies are gzip-compressed as concatenated gzip members
  when gzip is negotiated, with cancellation forwarded to the original
  producer.
- `Ctx` exposes the request timeout deadline, remaining budget, and expiry for
  cooperative handlers; access logs include protocol and remote address,
  report the dispatched status for handler failures, and use `499` for
  cancellations.
- Bounded per-client `RateLimit` token buckets return `429`/`Retry-After`, use
  fixed storage, evict least-recently-seen clients, and key on the peer IP
  without the ephemeral port so reconnects share one bucket.
- HTTP/3 TLS is verified with a real certificate identity and a pinned client
  public key, in addition to the synthetic QUIC handshake test.
- HTTP/1 WebSocket upgrades validate the RFC 6455 handshake, transfer transport
  ownership, and run a concrete session with text/binary sends, ping/pong,
  message deinit, and explicit or normal close frames; HTTP/2 and HTTP/3
  reject upgrades.
- `Etag` middleware derives a validator from the final buffered body and
  answers `If-None-Match` with `304`.
- Lock-free `Metrics` middleware exposes total, active, status-class, and
  latency counters through a snapshot API; handler errors use the dispatcher's
  status mapping and canceled requests are excluded from status classes.
- Shared protocol-neutral dispatch extracted for HTTP/1 and HTTP/2 adapters.
- `Http2Server(H)` serves cleartext h2c and TLS/ALPN `h2` through the same
  router, middleware, timeout, streaming, and error semantics, including
  lowercase response field mapping, graceful GOAWAY, and bounded
  `max_http2_concurrent_streams`/`max_http2_frame_payload` settings.
  All requests run in up to `max_concurrent_handlers` tasks; handlers pull
  DATA from bounded per-stream buffers while the connection owner serializes
  frame, HPACK, write, and response state.
- All three server adapters bound per-request allocations with the same
  `max_request_arena_bytes` fixed budget.
- `Ctx` exposes protocol, peer address, and TLS metadata populated by both
  adapters.
- Bounded `multipart/form-data` parsing through `Ctx.multipart`, with part
  count, header count, and header-byte limits. Boundaries are matched only at
  the start of the body or after CRLF, so boundary text inside field data is
  not treated as a delimiter. Filenames decode RFC 5987 `filename*` for
  UTF-8 and ISO-8859-1 (widened to UTF-8) and prefer it over `filename`.
- `Http3Server(H)` serves QUIC/TLS HTTP/3 through the shared dispatch,
  buffered/streaming responses, bounded QUIC limits, and one UDP accept loop
  with semaphore-bounded sessions. Each session runs up to
  `max_concurrent_handlers` handler tasks concurrently, serializes response
  submission, and caps advertised request-stream concurrency to the same
  bound.

## Verification

Commands run from `/home/passchaos/project-z/weft`:

```sh
zig fmt --check src test bench examples build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build examples
zig build bench -Doptimize=ReleaseFast
zig build bench-server -Doptimize=ReleaseFast
```

Results:

- Debug: 107/107 tests passed (74 unit, 33 package/integration).
- ReleaseFast: 107/107 tests passed.
- Examples build and `zig build run-hello` completes its request sequence.
- Router benchmark on the development host (ReleaseFast):

```text
router static: routes=1024 lookups=2000000 97.0 ns/lookup 10306879 lookups/s
router param:  routes=256  lookups=1000000 111.8 ns/lookup 8941462 lookups/s
```

The benchmark includes capture-array allocation from a fixed arena for the
parameter case. Numbers are indicative of this host, not a cross-machine
guarantee.

HTTP/1 keep-alive server throughput on the same host:

```text
server http1: requests=200000 16399.2 ns/request 60979 requests/s
```

## Remaining gaps

- Native step-driven DATA delivery for HTTP/3 request bodies; HTTP/2 uses
  netz's concurrent engine and HTTP/3 handlers are already concurrent.
- HTTP/3 adoption of `HandshakeServerSession.serveConcurrentStreams` waits on
  netz marking suppress-body (`HEAD`/`204`/`304`) streaming responses as
  finished, plus bounded (non-whole-body) `nextBody` delivery. Tracked in
  `netz/docs/weft-integration-requests.md`; weft already covers the buffered
  adapter's HEAD `Content-Length` behavior in `test/package_test.zig`.
- CPU-bound handler preemption without cancellation points.
