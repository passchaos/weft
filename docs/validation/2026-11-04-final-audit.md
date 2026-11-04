# weft final audit — 2026-11-04

Scope: verify the current tree against the repository constraints in
`AGENTS.md`, the feature list in `README.md`, and the measured performance
claims. Everything below is backed by files or commands in this checkout at
`22b3e3c`; the full test suite is 142/142 in Debug and ReleaseFast.

## 1. Repository constraints

| Constraint | Evidence |
| --- | --- |
| Application layer on netz; no duplicated codecs, framing, TLS, or QUIC state machines | `src/server.zig`, `src/http2_server.zig`, and `src/http3_server.zig` delegate parsing, framing, TLS, and QUIC to `netz.*`; weft files contain no frame codecs. |
| Concrete `Ctx`, `Handler`, `Response`, `Router`; no `Service<Request>` or `Layer<S>` | `src/ctx.zig:226` (`Handler`), `src/ctx.zig:262` (`Ctx`), `src/response.zig`, `src/router.zig`; no generic service/layer types exist. |
| Runtime seam at `std.Io`; no zio or OS types in public APIs | Public server/option/`Ctx` fields use `std.Io` and `std.Io.net` only (`src/server.zig`, `src/ctx.zig`, `src/limits.zig`). |
| Buffers, queues, and connection counts bounded by `Limits` | `src/limits.zig`; per-request arena in all three adapters; `max_streaming_window_bytes`, `max_response_bytes`, `max_middleware`, `max_multipart_parts`, `max_query_params`; `RouteOptions.max_body_bytes` and `.timeout` add per-route bounds. |
| `Ctx.next()` at most once per handler invocation | `src/ctx.zig:304` returns `error.NextNotAllowed` on a second call. |
| Small cohesive files | `src/` is split by responsibility (router, response, ctx, dispatch, stream, static, multipart, sse, websocket, accept, cookie, query, precondition, vary, drain, limits, errors) plus one file per middleware. |
| Tests next to modules; package tests in `test/` | Unit tests live in each `src/*.zig`; integration tests live in `test/package_test.zig`. |

## 2. Protocol and application surface

- HTTP/1.1 cleartext, HTTP/1.1 TLS, h2c, TLS/ALPN `h2`, and QUIC/TLS HTTP/3
  share one router, middleware chain, limits, error mapping, and `Ctx`.
- Incremental request bodies on all three adapters (`.pull`, `.duplex`/
  `.h2_stream`, `.h3_stream`), including per-route body budgets and
  `Content-Encoding` decoding via `Ctx.decodedReader()`.
- Streaming responses, response trailers, and request trailers on all
  adapters; HEAD/204/304 suppress bodies while preserving `Content-Length`.
- Response compression: gzip, deflate, Brotli, and zstd, with streamed bodies
  using concatenated gzip members or continuous deflate/Brotli/zstd state.
- Multipart: buffered `Ctx.multipart()` and bounded incremental
  `Ctx.multipartStream()` (with `DataReader.readAll` and safe part skipping).
- Static files: traversal-safe paths, validators, single/multipart ranges,
  precompressed sidecars, directory redirects, and download disposition.
- WebSocket: RFC 6455 handshake, subprotocols, ping/pong, close frames, and
  opt-in RFC 7692 `permessage-deflate`.
- Content negotiation (`Ctx.accepts`/`preferredType`), cookie prefixes and
  CHIPS `Partitioned`, mTLS peer chains, trusted `X-Forwarded-For`.
- Middleware: request id, text/JSON access logs, Basic auth, security headers,
  CORS, recovery, compression, Prometheus metrics, per-key rate limiting,
  ETag, server header, and Alt-Svc.

## 3. Verification commands

```sh
zig fmt --check src test bench examples build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build examples
zig build run-hello
zig build run-upload
zig build bench -Doptimize=ReleaseFast
zig build bench-server -Doptimize=ReleaseFast
zig build bench-h2 -Doptimize=ReleaseFast
zig build bench-h3 -Doptimize=ReleaseFast
zig build bench-middleware -Doptimize=ReleaseFast
zig build bench-static -Doptimize=ReleaseFast
```

Results:

- Debug: 142/142 (101 unit, 41 package/integration).
- ReleaseFast: 142/142.
- Examples build; `run-hello` and `run-upload` complete their request
  sequences (streaming upload, streaming multipart, SSE, Prometheus).
- Parser totality tests feed deterministic random bytes to the query,
  `Accept`, buffered/streaming multipart, and HTTP-date/precondition parsers.

## 4. Performance (reference host, ReleaseFast, quiet host)

| Workload | Result |
| --- | --- |
| HTTP/1 keep-alive | 9.0–9.3 µs/request, ~108–111k requests/s |
| HTTP/2 sequential | ~25 µs/request |
| HTTP/2 batch=32 GET | ~15 µs/request, ~66k requests/s |
| HTTP/3 sequential | ~61 µs/request, ~16k requests/s |
| HTTP/3 batch=32 GET | ~52 µs/request, ~19k requests/s |
| Router static / parameter | 52 ns / 91 ns per lookup |
| Middleware chain (requestId+Metrics+Etag+Compress) | 322 ns/request |
| Static file 64 KiB | 6.7–10.4 µs/request |
| Static conditional 304 | 1.55 µs/request, ~643k requests/s |

## 5. Known limitations

- HTTP/3 sequential latency remains above HTTP/2 (QUIC framing/recovery).
- CPU-bound handlers cannot be preempted without a cancellation point.
- WebSocket upgrades are HTTP/1.1 only.
- `Etag` covers buffered responses; streamed bodies are not hashed.
- Precompressed static sidecars are not range-addressable by design.
- Reported upstream: HTTP/1 error responses (431/414/413) are written and then
  closed with unread request bytes, so a peer may observe an RST before the
  response. Tracked in `netz/docs/weft-integration-requests.md`.

## 6. Upstream coordination

`netz/docs/weft-integration-requests.md` records the remaining protocol-level
requests (H3 error-response drain, optional `trailers()` locking) and the
before/after measurements that netz used for its concurrent-engine and QUIC
improvements.
