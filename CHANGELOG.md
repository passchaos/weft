# Changelog

All notable user-visible changes to `weft` are recorded here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project follows semantic versioning for public application APIs.

## [Unreleased]

### Added

- `docs/README.md` documentation index, `docs/architecture.md`, and
  `docs/api.md`.
- `docs/performance.md` for curated benchmark results and
  `docs/performance-journal.md` for append-only measurements.
- `docs/optimization-backlog.md` for tracked structure and documentation work.
- `zig build check` for formatting and test verification.
- `Ctx.sendEarlyHints(headers)` for interim `103 Early Hints` on HTTP/1.1,
  HTTP/2, and buffered HTTP/3 responses.
- `Etag.max_stream_bytes` for bounded, content-derived ETags on streamed
  responses with a declared length.
- MCP Streamable HTTP sessions (`Options.sessions`), server-initiated SSE via
  `Server.notify`, `Mcp-Session-Id` validation, and session termination.
- `test/interop/run.sh` and a CI workflow that exercise HTTP/1.1 and h2c with
  external clients.
- Unified TLS ALPN on `Http2Server` (`Options.alpn_http1`) for `h2` and
  `http/1.1` on one port, with a buffered HTTP/1.1 fallback.
- HTTP/1.1 `Upgrade: h2c` via `Http2Server.Options.h2c_upgrade`.
- RFC 8441 WebSocket over HTTP/2 extended CONNECT, gated by
  `Limits.http2_enable_connect_protocol`, with a stream-agnostic frame
  transport in netz.
- `weft.session`: bounded in-memory session store, middleware, rotation,
  destruction, and typed/JSON values.
- `weft.csrf`: session-bound CSRF middleware with safe-method tokens,
  `x-csrf-token` validation, and optional Origin allow lists.
- `weft.jwt`: HS256 and EdDSA compact JWS encode/verify with standard-claim
  validation, plus `weft.middleware.Bearer`.
- `weft.WebTransportServer`: WebTransport sessions over QUIC/HTTP/3 with
  datagrams, streams, exact-path routing, and bounded buffers.
- `weft.GrpcServer`: unary gRPC dispatch over h2c or TLS/ALPN `h2`, with
  status responses, per-connection call limits, and graceful GOAWAY.
- `weft.GrpcStreamingServer`: streaming gRPC dispatch with collected request
  messages and multi-message responses.
- gRPC-Web mode for `GrpcServer` (`Options.grpc_web`) with optional CORS.
- `weft.tls.ReloadableIdentity`: atomic TLS certificate rotation for HTTP/1
  and HTTP/2 listeners via netz's identity provider.
- `weft.session.FileStore` and `Store.Backend` for shared-filesystem or
  external session storage; CSRF form-field tokens.
- `weft.jwt` RS256/ES256 verification and `KeySet` JWKS parsing for OIDC ID
  tokens.
- `weft.middleware.Cache` bounded GET response cache.
- `weft.cookie_signer.Signer` HMAC-SHA256 signed cookie values.
- CSP templates with `{nonce}` rendering in `SecurityHeaders`.
- Router `nest`, `merge`, named routes, and `urlFor` reverse URL generation.

### Changed

- README is now a short entry point; request, adapter, middleware, routing,
  static-file, OpenAPI/MCP, and limits details live under `docs/guide/`.
- Dated validation documents are explicitly marked as historical snapshots.
- Build targets share helpers in `build/helpers.zig` instead of repeating
  module and run-step wiring.
- Package integration tests are split by adapter and feature under `test/`.
- `ctx`, `router`, `compress`, `static_files`, `mcp`, `openapi`, and
  `multipart_stream` are split into focused modules under `src/`.
- HTTP/1, HTTP/2, and HTTP/3 adapters share response-budget, buffered-body,
  header-view, and internal-error helpers.
- `src/root.zig` is the only public barrel. Intermediate modules no longer
  re-export unrelated application types.

### Removed

- Middleware submodule aliases such as `weft.middleware.cors` and
  `weft.middleware.compress_mod`. Use the exported types and functions
  (`weft.middleware.Cors`, `weft.middleware.Compress`, and so on) instead.
- The `weft.mcp.Handler` and `weft.openapi.Handler` aliases; use `weft.Handler`.

### Fixed

- Removed a corrupted trailing line from the README.

## [0.1.0] - 2026-11-10

Initial development snapshot.

### Added

- Concrete `Ctx`, `Handler`, `Response`, and `Router` application API on top of
  `netz`, with the runtime seam at `std.Io`.
- HTTP/1.1 cleartext, TLS, and Unix-socket adapters; h2c and TLS/ALPN `h2`;
  QUIC/TLS HTTP/3; and HTTP/1.1 WebSocket upgrades.
- Segment-trie routing with groups, automatic `OPTIONS`, `405` with `Allow`,
  and `HEAD` fallback.
- Decoded path/query/cookie inputs, typed locals, JSON/form/multipart body
  helpers, incremental request bodies, streamed responses, SSE, and trailers.
- Middleware for request ids, access logs, security headers, Basic auth, CORS,
  recovery, compression, ETags, Alt-Svc, Prometheus metrics, and bounded rate
  limiting.
- Static-file serving with validators, preconditions, ranges, index files, and
  precompressed sidecars.
- OpenAPI 3.1 document generation and a Model Context Protocol server over
  Streamable HTTP.
- `Limits`-bounded request, response, middleware, multipart, query, and
  connection resources.
