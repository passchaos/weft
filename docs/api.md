# Public API

Everything in this document is exported by `src/root.zig` and available as
`weft.<name>`. Modules not listed here are internal.

## Core types

| Export | Description |
| --- | --- |
| `Ctx` | Concrete per-request context: accessors, body helpers, trailers, locals |
| `Handler` | Handler contract: `call_fn(context, *Ctx)` plus `call(ctx)` |
| `Response` | Status, headers, buffered body, stream, SSE, WebSocket upgrade |
| `Header` | `netz.http1.Header` alias used by request and response views |
| `Limits` | Every request, response, middleware, multipart, query, and connection budget |
| `Locals` | Type-keyed request-scoped storage |
| `Param` | One path capture |
| `Protocol` | `http_1_1`, `http_2`, or `http_3` |
| `ClientInfo` | Peer address, protocol, TLS flag, and mTLS certificate chain |
| `BodyReader` | Buffered, limited, decoded, replay, H2, or H3 request-body reader |
| `StreamBody` / `StreamWriter` | Streaming response producer contract |
| `SseEvent` | Server-sent event value |
| `WebSocketSession` / `WebSocketUpgrade` | RFC 6455 session and upgrade contract (HTTP/1.1 and HTTP/2/3 extended CONNECT) |

## Constructors and helpers

| Export | Description |
| --- | --- |
| `handler(f)` | Wrap `fn (*Ctx) anyerror!void` as a `Handler` |
| `handlerFor(H, f)` | Wrap `fn (*H, *Ctx) anyerror!void` as a `Handler` |
| `withContext(T, context, f)` | Wrap a parameterized middleware/handler |
| `reasonFor(status)` | Default reason phrase for a status code |
| `validateHeaderName(name)` / `validateHeaderValue(value)` | Header validation |
| `max_params` | Maximum path captures per route |
| `Ctx.sendEarlyHints(headers)` | Interim `103 Early Hints` on HTTP/1.1, HTTP/2, and buffered HTTP/3 responses |

## Router

| Export | Description |
| --- | --- |
| `Router(H)` | Method-and-path router generic over the application context type |
| `RouteOptions` | Middleware, streaming, body budget, timeout, OpenAPI, inline bodyless |
| `GroupOptions` | Group middleware |
| `Route` | Registered route metadata |
| `Match` | Matched route, captures, path, and query |
| `Prepared` | Route lookup performed before the body is read |
| `AllowedMethods` | Bounded `Allow` field builder |
| `Resolution` | Matched, method-not-allowed, or not-found result |
| `max_path_segments` / `max_allowed_methods` | Router bounds |

## Servers

| Export | Description |
| --- | --- |
| `Server(H)` / `Options` | HTTP/1.1 cleartext, TLS, and Unix-socket adapter |
| `Http2Server(H)` / `Http2Options` | h2c and TLS/ALPN `h2` adapter; optional `alpn_http1` TLS fallback and `h2c_upgrade` cleartext mode |
| `Http3Server(H)` / `Http3Options` | QUIC/TLS HTTP/3 adapter |
| `WebTransportServer(H)` / `WebTransportSession` | QUIC/TLS WebTransport sessions, datagrams, and streams |
| `GrpcServer(H)` / `grpc.Context` | Unary gRPC (native or gRPC-Web) over h2c or TLS/ALPN `h2` |
| `GrpcStreamingServer(H)` / `grpc_streaming.Context` | Streaming gRPC over h2c or TLS/ALPN `h2` |

## Request data

| Export | Description |
| --- | --- |
| `QueryPair` | One decoded query pair |
| `query` | Query decoding helpers |
| `cookie` / `SetCookie` / `SameSite` | Cookie lookup and validated `Set-Cookie` serialization |
| `cookie_signer` / `Signer` | HMAC-SHA256 signed cookie values |
| `accept` | `Accept` negotiation helpers |
| `multipart` / `MultipartPart` / `MultipartForm` | Buffered `multipart/form-data` parsing |
| `multipart_stream` / `MultipartStream` / `MultipartStreamPart` | Incremental multipart parsing |
| `RouteFailure` | Fallback-handler inspection value (`not_found`, `method_not_allowed`) |

## Features

| Export | Description |
| --- | --- |
| `StaticFiles` | Static-file handler with validators, ranges, and sidecars |
| `MimeType` / `default_mime_types` | MIME table used by `StaticFiles` |
| `stream` | Streaming response helpers |
| `sse` | Server-sent event writer |
| `websocket` | WebSocket session and upgrade types |
| `session` | Bounded session store, middleware, and request-local `Session` view |
| `csrf` | Session-bound CSRF middleware and `Token` |
| `jwt` | HS256/RS256/ES256/EdDSA verification, JWKS key sets, and encode helpers |
| `tls` | Reloadable TLS server identity provider |
| `webtransport` | WebTransport server adapter types |
| `grpc` | gRPC status, context, and unary/gRPC-Web server adapter types |
| `grpc_streaming` | Streaming gRPC server adapter types |
| `middleware` | Built-in middleware namespace |
| `logging` | kron access-log middleware and fallback diagnostics |
| `openapi` | OpenAPI 3.1 types, renderer, and `Document` |
| `mcp` | Model Context Protocol server, tool/resource/prompt types, sessions, and SSE notifications (`Server.notify`) |

## Middleware namespace

`weft.middleware` exports:

- `requestId`, `serverHeader`, `log`, `Log`, `LogFormat`
- `BasicAuth`, `SecurityHeaders`, `securityHeaders`, `Cors`
- `recoverHandler`, `Compress`, `compress`
- `Metrics`, `metrics`, `RateLimit`, `Etag`, `AltSvc`, `Cache`, `Bearer`,
  `bearer`, `Session`, `Csrf`

## Runtime dependency

`weft.netz` re-exports the `netz` module. Public signatures use a small set of
netz types: `Header`, `netz.http1.Method`, `TlsListenOptions`,
`WriteStrategy`, and the WebSocket `Frame` / `OwnedMessage` values. These are
supported escape hatches and follow the pinned netz version. No zio or
operating-system types are exposed; the runtime seam is `std.Io`.
