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
- `Ctx.trailers()` and `Ctx.trailer(name)` expose request trailers for all
  adapters: HTTP/1 buffered and streaming (after the body is consumed),
  buffered HTTP/2/HTTP/3, and streaming HTTP/2/HTTP/3 via the concurrent
  engines. Trailer field bytes are copied into the request arena so they
  outlive transport-owned metadata.
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
- Middleware: request-id propagation/validation, request-id-aware logging
  (plain text or compact JSON per request),
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
- Streamed response bodies use concatenated gzip members or continuous
  deflate/Brotli/zstd encoder state
  (`vort.deflate.ZlibIncrementalBestEncoder`,
  `vort.br.IncrementalPlannedStreamEncoder`,
  `vort.zstd.NativeIncrementalFrameEncoder`) depending on the negotiated
  coding, with cancellation forwarded to the original producer.
- `Ctx` exposes the request timeout deadline, remaining budget, and expiry for
  cooperative handlers; access logs include protocol and remote address,
  report the dispatched status for handler failures, and use `499` for
  cancellations.
- Bounded per-client `RateLimit` token buckets return `429`/`Retry-After`, use
  fixed storage, evict least-recently-seen clients, and key on the peer IP
  without the ephemeral port so reconnects share one bucket. An optional
  hashed `key_header` (for example an API key) overrides the address.
- HTTP/3 TLS is verified with a real certificate identity and a pinned client
  public key, in addition to the synthetic QUIC handshake test.
- HTTP/1 WebSocket upgrades validate the RFC 6455 handshake, transfer transport
  ownership, and run a concrete session with text/binary sends, ping/pong,
  message deinit, and explicit or normal close frames. Opt-in
  `permessage-deflate` (RFC 7692) negotiates `Sec-WebSocket-Extensions` and
  configures the netz session's send/receive history windows. HTTP/2 and HTTP/3
  reject upgrades.
- `Etag` middleware derives a validator from the final buffered body and
  answers `If-None-Match` with `304`.
- `AltSvc` middleware advertises an HTTP/3 endpoint on HTTP/1.1 and HTTP/2
  responses and skips the header on HTTP/3 requests.
- Lock-free `Metrics` middleware exposes total, active, status-class, and
  latency counters through a snapshot API; handler errors use the dispatcher's
  status mapping and canceled requests are excluded from status classes.
  Snapshots render Prometheus text exposition with a validated metric
  namespace.
- Shared protocol-neutral dispatch extracted for HTTP/1 and HTTP/2 adapters.
- `Http2Server(H)` serves cleartext h2c and TLS/ALPN `h2` through the same
  router, middleware, timeout, streaming, and error semantics, including
  lowercase response field mapping, graceful GOAWAY, and bounded
  `max_http2_concurrent_streams`/`max_http2_frame_payload` settings.
  All requests run in up to `max_concurrent_handlers` tasks; handlers pull
  DATA from bounded per-stream buffers while the connection owner serializes
  frame, HPACK, write, and response state. The package test issues a
  32-stream GET batch and a 32-stream POST upload batch to cover the
  concurrent write and request-body paths.
- All three server adapters bound per-request allocations with the same
  `max_request_arena_bytes` fixed budget.
- `RouteOptions.max_body_bytes` adds a per-route body budget: buffered bodies
  above it are rejected with `413` before dispatch, and streaming readers are
  wrapped so `Ctx.bodyReader()`/`Ctx.readBody()` stop at the route limit.
- `RouteOptions.timeout` overrides `Limits.request_timeout` per route and
  drives both `Ctx.deadline()` and the `503` cancellation race; zero values
  are rejected at registration.
- `Ctx.accepts`/`Ctx.preferredType` negotiate the `Accept` header with
  wildcards, q-values, and most-specific-range precedence.
- `Ctx` exposes protocol, peer address, TLS metadata, and the verified client
  certificate chain for mutual TLS, populated by every adapter. The package
  test completes a real pinned mTLS handshake and asserts the chain length. `Limits.trust_forwarded_for` optionally replaces the peer address
  with the leftmost `X-Forwarded-For` entry; it is off by default so clients
  cannot spoof logs or rate-limit buckets.
- Bounded `multipart/form-data` parsing through `Ctx.multipart`, with part
  count, header count, and header-byte limits. Boundaries are matched only at
  the start of the body or after CRLF, so boundary text inside field data is
  not treated as a delimiter. Filenames decode RFC 5987 `filename*` for
  UTF-8 and ISO-8859-1 (widened to UTF-8) and prefer it over `filename`.
- `Ctx.multipartStream()` parses `multipart/form-data` incrementally over a
  streaming body reader with a fixed window, one part at a time, and a
  whole-body budget. The window is capped at half the request arena. Package
  tests cover 200 KiB over HTTP/1, 1 KiB over HTTP/2, and 300 KiB over HTTP/3,
  and a differential test compares it with the buffered parser across every
  source chunk size. `DataReader.readAll(allocator, max_bytes)` drains one part
  with its own bound, and `nextPart` skips any unread remainder. Encoded
  (`Content-Encoding`) bodies return `415`; the buffered parser handles them.
- `Http3Server(H)` serves QUIC/TLS HTTP/3 through the shared dispatch,
  buffered/streaming responses, bounded QUIC limits, and one UDP accept loop
  with semaphore-bounded sessions. Each session uses netz's owner-serialized
  concurrent engine: up to `max_concurrent_handlers` handler tasks pull
  request DATA through `.h3_stream` (bounded resident window), responses and
  trailers are serialized by the owner, HEAD/204/304 suppress the body while
  preserving `Content-Length`, and advertised request-stream concurrency is
  capped to the same bound. The package test uploads 400 KiB through a
  64 KiB resident window and issues 32-stream GET and POST upload batches.

## Verification

Commands run from `/home/passchaos/project-z/weft`:

```sh
zig fmt --check src test bench examples build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build examples
zig build bench -Doptimize=ReleaseFast
zig build bench-server -Doptimize=ReleaseFast
zig build bench-middleware -Doptimize=ReleaseFast
zig build bench-static -Doptimize=ReleaseFast
zig build bench-h2 -Doptimize=ReleaseFast
zig build bench-h3 -Doptimize=ReleaseFast
```

Results:

- Debug: 131/131 tests passed (93 unit, 38 package/integration).
- ReleaseFast: 131/131 tests passed.
- Examples build and `zig build run-hello` completes its request sequence.
- Router benchmark on the development host (ReleaseFast):

```text
router static: routes=1024 lookups=2000000 52.1 ns/lookup 19205250 lookups/s
router param:  routes=256  lookups=1000000 91.2 ns/lookup 10962601 lookups/s
```

Capture-free routes no longer allocate a zero-length parameter array, which
cut the static path from ~97 ns to ~52 ns. The parameter case still includes
capture-array allocation from a fixed arena. Numbers are indicative of this host, not a cross-machine
guarantee.

Static-file handler throughput (in-process, 64 KiB and 1 KiB files):

```text
static large.bin: 6847.9 ns/request 146030 requests/s 9126.9 MiB/s
static small.txt: 3275.3 ns/request 305320 requests/s  298.2 MiB/s
```

Application-layer middleware overhead (fixed arena, no I/O):

```text
baseline (handler only):  75.3 ns/request
requestId:               195.8 ns/request
Metrics:                 141.4 ns/request
Etag:                    151.9 ns/request
Compress:                 96.4 ns/request
all four combined:       322.0 ns/request
```

`requestId` now seeds a per-thread PRNG once instead of calling
`randomSecure` per request (504.5 → 195.8 ns).

HTTP/1 keep-alive server throughput on the same host:

```text
server http1: requests=200000 8993.9 ns/request 111187 requests/s
```

Repeated runs measured 9.0–9.3 µs per request (108k–111k requests/s) on a quiet
host; earlier 16 µs runs happened while sibling repositories were compiling in
parallel, so treat these numbers as host-load dependent.

HTTP/2 cleartext (h2c) throughput on the same host, sequential and batched
(32 concurrent streams), after netz pooled its concurrent handlers
(`2adc9c63`):

```text
server h2 sequential:      requests=100000 25418.3 ns/request 39342 requests/s
server h2 batched:         requests=128000 15159.2 ns/request 65966 requests/s
server h2 upload batched:  requests=128000 19249.2 ns/request 51950 requests/s
```

H2 batched GET throughput now exceeds HTTP/1 keep-alive; batched 2 KiB uploads
reach ~52k req/s, and the sequential path still pays HTTP/2 framing.
`-Dh2-batch=<n>` and `-Dh2-batch-iterations=<n>` override the benchmark shape.

HTTP/3 synthetic-handshake throughput on the same host with the default 1 ms
weft poll interval and netz's active-command wake race fix (`462906fc`):
sequential requests, batched GETs, and batched 2 KiB uploads, all 32 streams
per batch:

```text
server h3 sequential:      requests=10000 75995.9 ns/request 13159 requests/s
server h3 batched:         requests=32000 58856.3 ns/request 16991 requests/s
server h3 upload batched:  requests=32000 75627.2 ns/request 13223 requests/s
```

netz's QUIC recovery-queue caching (`8140c2f6`) cut 32-stream batched GETs from
~151 µs to ~59 µs per request and uploads from ~181 µs to ~76 µs. With
`-Dh3-batch=8` the same host reports 53.2 µs (18.8k requests/s) for GETs and
60.6 µs (16.5k requests/s) for uploads, so 32-stream batching is now within
10–25% of the eight-stream path.

`-Dh3-poll-us=5000` measured 89.5 µs/req sequential and 186.5 µs/req batched,
confirming the 1 ms default is still the better trade-off after netz's
command-wake fixes. `-Dh3-batch=8` reports 44.3 µs/req (22.6k requests/s) for
GETs and 71.0 µs/req (14.1k requests/s) for uploads, so owner/worker contention
starts above eight concurrent streams.

A 5 ms poll interval measured ~10.1 ms/req sequentially before these netz
fixes; the 1 ms default plus bounded active-command polling and the wake race
fix reduced sequential latency to ~71 µs.

With `-Dh3-batch=8` the same benchmark reports 52.1 µs/req (19.2k requests/s)
for GETs and 84.7 µs/req (11.8k requests/s) for uploads. Per-request throughput
falls at 32 concurrent streams, so owner/worker contention above roughly eight
streams remains a netz tuning item.

## Remaining gaps

- HTTP/3 sequential latency is ~76 µs/req versus ~25 µs for HTTP/2; the gap
  is dominated by QUIC/HTTP/3 framing and recovery. Batched throughput is now
  ~17k req/s at 32 streams versus ~19k at eight, so the previous 3× contention
  penalty is largely resolved.
- CPU-bound handler preemption without cancellation points.
