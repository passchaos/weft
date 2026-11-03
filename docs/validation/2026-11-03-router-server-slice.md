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
  policy, MIME detection, ETag/`If-None-Match`, single `Range` support
  (`206`/`416`), index files, and streamed file reads.

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

- Debug: 46/46 tests passed (31 unit, 15 package/integration).
- ReleaseFast: 46/46 tests passed.
- Examples build and `zig build run-hello` completes its request sequence.
- Router benchmark on the development host (ReleaseFast):

```text
router static: routes=1024 lookups=2000000 80.6 ns/lookup 12403475 lookups/s
router param:  routes=256  lookups=1000000 90.3 ns/lookup 11069290 lookups/s
```

The benchmark includes capture-array allocation from a fixed arena for the
parameter case. Numbers are indicative of this host, not a cross-machine
guarantee.

## Remaining gaps

- Streaming request bodies (responses are streamed).
- Multi-range and multi-encoding responses.
- Preemptive per-request deadlines for handlers.
- TLS and HTTP/2/HTTP/3 adapters.
- Compression currently supports gzip only.
