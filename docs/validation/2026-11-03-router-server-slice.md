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
- Typed JSON/form body helpers, cookie lookup and validated `Set-Cookie`
  serialization.
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
- Streaming response bodies through a concrete `StreamBody`/`StreamWriter` seam,
  with fixed or chunked framing, a `max_response_bytes` producer budget,
  HEAD/body-forbidden suppression, and cancellation cleanup.
- `StaticFiles` handler with traversal-safe normalization, dotfile/symlink
  policy, MIME detection, ETag/`If-None-Match`, single and multipart `Range`
  support (`206`/`416`), index files, and streamed file reads.
- Request `Content-Encoding` decoding through `Ctx.decodedBody`, used by
  `bodyJson`/`bodyForm`; malformed JSON maps to `400`, unsupported codings to
  `415`, and oversized decoded bodies to `413`.
- CORS preflight validates requested headers against a configured allow list.
- Optional TLS listener through `Options.tls`, reusing Netz's TLS transport while
  applying weft HTTP limits and a bounded accept/handshake budget.
- Optional `Limits.request_timeout` races the middleware/handler chain against a
  timer, cancels at the next cancellation point, and returns `503`.
- Response compression negotiates gzip or deflate from `Accept-Encoding`
  quality values, honors `no-transform`, and returns `406` when identity is
  explicitly refused.
- Lock-free `Metrics` middleware exposes total, active, status-class, and
  latency counters through a snapshot API.
- Shared protocol-neutral dispatch extracted for HTTP/1 and HTTP/2 adapters.
- `Http2Server(H)` serves cleartext h2c and TLS/ALPN `h2` through the same
  router, middleware, timeout, streaming, and error semantics, including
  lowercase response field mapping and graceful GOAWAY.
- `Ctx` exposes protocol, peer address, and TLS metadata populated by both
  adapters.
- Bounded `multipart/form-data` parsing through `Ctx.multipart`, with part
  count, header count, and header-byte limits.

## Verification

Commands run from `/home/passchaos/project-z/weft`:

```sh
zig fmt --check src test bench examples build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build examples
zig build bench -Doptimize=ReleaseFast
```

Results:

- Debug: 60/60 tests passed (38 unit, 22 package/integration).
- ReleaseFast: 60/60 tests passed.
- Examples build and `zig build run-hello` completes its request sequence.
- Router benchmark on the development host (ReleaseFast):

```text
router static: routes=1024 lookups=2000000 89.0 ns/lookup 11236190 lookups/s
router param:  routes=256  lookups=1000000 118.9 ns/lookup 8412830 lookups/s
```

The benchmark includes capture-array allocation from a fixed arena for the
parameter case. Numbers are indicative of this host, not a cross-machine
guarantee.

## Remaining gaps

- Streaming request bodies and streaming multipart/file uploads.
- Brotli and zstd response compression.
- CPU-bound handler preemption without cancellation points.
- Concurrent HTTP/2 stream dispatch and HTTP/3.
