# Architecture

`weft` is the application layer on top of `netz`. This document maps the
module boundaries, the request lifecycle, and the ownership rules that keep the
three protocol adapters on one application surface.

## Layers

```text
application handlers / middleware
             |
             v
  Ctx, Handler, Router, Response, Limits   (weft application surface)
             |
             v
  dispatch + adapter mapping               (weft)
             |
             v
  netz HTTP/1, HTTP/2, HTTP/3, TLS, QUIC   (protocol code)
             |
             v
  std.Io                                   (runtime seam: zio or another backend)
```

Rules:

- netz owns codecs, framing, TLS, QUIC, flow control, and connection state.
- weft owns dispatch, routing, middleware, request decoding, response
  building, and per-request budgets.
- Public APIs use `std.Io`; zio and operating-system types do not leak.
- `src/root.zig` is the only public barrel.

## Module map

### Public entry point

| Module | Owns |
| --- | --- |
| `src/root.zig` | Public exports for the whole package |
| `src/limits.zig` | `Limits` and the mapping to each netz adapter limit |
| `src/response.zig` | `Response`, `Header`, status reasons, header validation |
| `src/stream.zig` | Streaming response writer and body producer contract |

### Request core

| Module | Owns |
| --- | --- |
| `src/ctx.zig` | `Ctx`, request accessors, body helpers, trailers, locals access |
| `src/body.zig` | `BodyReader` and the replay, limited, decoded, H2, and H3 readers |
| `src/handler.zig` | `Handler`, `Locals`, `Param`, `Protocol`, `ClientInfo`, `handler`, `handlerFor`, `withContext` |
| `src/dispatch.zig` | Middleware chain, route preparation, fallback responses, error mapping |
| `src/bounded_arena.zig` | Fixed request arena with an inline first chunk |
| `src/errors.zig` | Handler-error to status mapping and peer-disconnect classification |
| `src/drain.zig` | Bounded cooperative group drain |

### Routing

| Module | Owns |
| --- | --- |
| `src/router.zig` | `Router`, `Route`, `RouteOptions`, groups, `Match`, `Prepared`, `AllowedMethods`, `Resolution` |
| `src/router/trie.zig` | Segment trie, captures, pattern validation, specificity, method matching |

### Adapters

| Module | Owns |
| --- | --- |
| `src/server.zig` | HTTP/1.1 cleartext, TLS, and Unix-socket adapter |
| `src/http2_server.zig` | h2c and TLS/ALPN `h2` adapter, including `inline_bodyless` |
| `src/http3_server.zig` | QUIC/TLS HTTP/3 adapter, including `inline_bodyless` |
| `src/adapter/write.zig` | Shared response-body budget accounting |
| `src/adapter/body.zig` | Shared buffered-body reader for HTTP/2 and HTTP/3 streams |
| `src/adapter/header_view.zig` | Shared HPACK/QPACK to HTTP/1 header-view mapping |
| `src/adapter/response.zig` | Shared internal-error response builder |

### Parsing and content helpers

| Module | Owns |
| --- | --- |
| `src/query.zig` | Percent-decoded query pairs |
| `src/cookie.zig` | Request cookies and validated `Set-Cookie` serialization |
| `src/accept.zig` | `Accept` negotiation |
| `src/quality.zig` | Shared `q`-value parsing |
| `src/precondition.zig` | RFC 9110 conditional request evaluation |
| `src/target.zig` | Origin-form and absolute-form target splitting |
| `src/vary.zig` | `Vary` accumulation |
| `src/multipart.zig` | Buffered `multipart/form-data` parsing |
| `src/multipart_stream.zig` | Incremental multipart stream state machine |
| `src/multipart/reader.zig` | Per-part `DataReader` |
| `src/multipart/delimiter.zig` | Boundary-line detection |

### Features

| Module | Owns |
| --- | --- |
| `src/static_files.zig` | Static-file handler and streaming |
| `src/static/path.zig` | Traversal-safe path normalization and redirect targets |
| `src/static/range.zig` | Single and multipart `Range` parsing |
| `src/static/variants.zig` | Precompressed sidecar selection and freshness |
| `src/sse.zig` | Server-sent event formatting |
| `src/websocket.zig` | RFC 6455 session, upgrade, and handshake validation |
| `src/openapi.zig` | OpenAPI facade |
| `src/openapi/types.zig` | Schema, operation, and document option types |
| `src/openapi/render.zig` | OpenAPI JSON rendering |
| `src/openapi/ui.zig` | Swagger UI page |
| `src/openapi/document.zig` | `Document` and its handlers |
| `src/mcp.zig` | MCP facade |
| `src/mcp/types.zig` | Tools, resources, prompts, and options |
| `src/mcp/server.zig` | JSON-RPC dispatch and registration |
| `src/logging.zig` | kron access-log middleware and fallback diagnostics |

### Middleware

`src/middleware/mod.zig` is the middleware namespace. Each middleware lives in
its own file. Compression is the only middleware with submodules:

| Module | Owns |
| --- | --- |
| `src/middleware/compress.zig` | Facade and buffered/streamed dispatch |
| `src/middleware/compress/negotiate.zig` | Coding selection, `q` values, content-type checks |
| `src/middleware/compress/gzip.zig` | Buffered gzip and streaming gzip members |
| `src/middleware/compress/deflate.zig` | Buffered deflate and incremental encoder |
| `src/middleware/compress/brotli.zig` | Buffered Brotli and incremental encoder |
| `src/middleware/compress/zstd.zig` | Buffered zstd and incremental encoder |
| `src/middleware/compress/continuous.zig` | Shared continuous stream wrapper |

## Request lifecycle

1. An adapter accepts a connection and lets netz parse the request head.
2. The adapter calls `Router.prepare`/`Router.resolve` once and keeps the
   resulting `Prepared` value.
3. `dispatch` builds a `Ctx` with the request arena, `Limits`, client info, and
   an optional body reader.
4. Server, group, and route middleware run in order. `ctx.next()` continues;
   not calling it short-circuits. It may be called at most once.
5. The handler writes headers, a buffered body, a stream, an SSE stream, a
   WebSocket upgrade, or a status-only response.
6. The adapter maps `Response` back to the protocol and writes it.
7. The adapter drains any unread request body, publishes trailers, and decides
   whether the connection stays reusable.

HTTP/2 and HTTP/3 may run bodyless `inline_bodyless` routes on the connection
owner; all other requests use bounded handler tasks.

## Ownership and budgets

- The request arena is fixed and bounded by `Limits.max_request_arena_bytes`.
  Request headers, params, decoded query values, buffered bodies, middleware
  locals, response headers, and buffered response bodies come from it.
- Buffered response bodies are borrowed slices. `ctx.text` and
  `ctx.setBody` do not copy; `ctx.json` allocates in the arena. Handlers must
  not return stack buffers.
- Streaming producers own their resources and must release them on success or
  error. `cancel_fn` releases resources when the response is discarded before
  the producer starts.
- A streaming `BodyReader` borrows transport memory until the next `next` call.
  `Ctx.readBody()` copies the body into the arena and caches it.
- Compressed bodies are staged in the server allocator and copied into the
  arena once, so encoder growth cannot exhaust a body that fits the arena.
- `Locals` is a fixed inline array keyed by `@typeName(T)`; `max_locals` bounds
  the number of distinct values.

## Adapter differences

| Capability | HTTP/1.1 | HTTP/2 | HTTP/3 |
| --- | --- | --- | --- |
| Transport | TCP, TLS, Unix socket | TCP h2c or TLS/ALPN `h2`, Unix h2c | QUIC/TLS |
| Request body | netz pull reader | duplex or concurrent stream | concurrent stream |
| Streaming responses | fixed or chunked | DATA frames | DATA frames |
| Trailers | only with `TE: trailers` | always after body | always after body |
| Inline bodyless | n/a | `inline_bodyless` | `inline_bodyless` |
| WebSocket | yes | `400` | `400` |
| Request concurrency | one request per connection worker | bounded handler tasks per connection | bounded handler tasks per session |

All adapters share `Router`, `Ctx`, middleware, decoded inputs, `Limits`, and
error mapping.

## Dependency surface

`weft` re-exports `netz` as `weft.netz` and uses a small number of netz types
in public signatures:

- `netz.http1.Header` (as `weft.Header`)
- `netz.http1.Method` in route registration
- `netz.http1.runtime.TlsListenOptions` in `Options.tls`
- `netz.http1.runtime.WriteStrategy` in `Limits.write_strategy`
- `netz.websocket.Frame` and `netz.websocket.runtime.OwnedMessage` in the
  WebSocket session

These are deliberate escape hatches for advanced transport configuration.
They are as stable as the pinned netz version. zio and OS types are not part of
the public surface; the runtime seam stays `std.Io`.

## Tests

- Unit tests live next to the module they verify. Larger modules may place
  their tests in a sibling `*_test.zig` file.
- Package-level integration tests live in `test/` and are split by adapter or
  feature (`http1_test.zig`, `http2_test.zig`, `http3_test.zig`, `tls_test.zig`,
  `static_test.zig`, `middleware_test.zig`, `websocket_test.zig`,
  `multipart_test.zig`, and `openapi_mcp_test.zig`).
- `test/package_test.zig` is the aggregator root for the package tests.
