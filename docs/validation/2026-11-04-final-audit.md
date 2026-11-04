# weft final audit — 2026-11-04

Scope: verify the current tree against the repository constraints in
`AGENTS.md`, the feature list in `README.md`, and the measured performance
claims. Everything below is backed by files or commands in this checkout;
the full test suite is 162/162 in Debug and ReleaseFast.

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
- HTTP/1 origin-form and absolute-form request targets are both routed by path
  and query; `ctx.target()` preserves the original wire target.
- HTTP/1 and prior-knowledge h2c also serve over Unix-domain sockets via
  `unix_path`; TLS is rejected there, and `clientAddress()` is `null` unless a
  trusted `X-Forwarded-For` supplies one.
- HTTP/1 protocol-error responses (`400/408/413/414/431`) are written through
  `Connection.respondAndClose`, which permits one final write after a failed
  read, then half-closes and drains within a 250 ms budget.
- Request-head budgets (`max_head_bytes`, `max_request_headers`,
  `max_request_target_bytes`) are enforced on all adapters; HTTP/3 also checks
  the decoded QPACK field-section size before header conversion.
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

- Debug: 162/162 (110 unit, 52 package/integration).
- ReleaseFast: 162/162.
- Examples build; `run-hello` and `run-upload` complete their request
  sequences (streaming upload, streaming multipart, SSE, Prometheus).
- HTTP/1 `Expect: 100-continue` uploads complete through a streaming route.
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
- `CONNECT` (HTTP/1 authority-form, HTTP/2/3 tunnel or extended CONNECT)
  receives `501` because weft exposes no tunnel writer.
- Unix sockets serve HTTP/1 and h2c; TLS on a Unix socket is rejected, and the
  HTTP/3 adapter remains TCP/UDP-addressed.

## 6. Upstream coordination

`netz/docs/weft-integration-requests.md` records the protocol-level requests
and their outcomes: H3 concurrent bodies/streams, streaming trailers,
`drainAndClose`, and `respondAndClose` are delivered; only optional
`ConcurrentStream.trailers()` locking remains.
