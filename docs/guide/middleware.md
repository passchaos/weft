# Middleware and logging

The middleware contract, execution order, built-in middleware, and the kron
access-log integration.

[Back to the documentation index](../README.md)

## Middleware

A middleware is a plain function that calls `ctx.next()` to continue:

```zig
fn auth(ctx: *weft.Ctx) anyerror!void {
    if (ctx.header("authorization") == null) {
        ctx.setStatus(401);
        return ctx.text("Unauthorized");
    }
    try ctx.next();
}
```

`next()` may be called at most once per handler invocation. Not calling it
short-circuits the chain. A response written before `next()` is preserved.

Middleware runs in this order:

1. server-level `Options.middleware` (including for `404`, `405`, and automatic
   `OPTIONS`);
2. group middleware, outer group first;
3. route middleware in registration order;
4. the route handler.

Built-ins:

- `requestId` — preserves a validated incoming `X-Request-Id` or generates a
  128-bit hex id, and always echoes it in the response.
- `serverHeader` — adds `Server` unless already set.
- `log` / `Log` — logs method, target, protocol, remote address, request id,
  status, and elapsed nanoseconds. Handler failures report the status dispatch
  will emit, and client cancellations log as `499`. `Log{ .format = .json }`
  emits one compact JSON object per request with JSON-escaped values.
- `securityHeaders` / `SecurityHeaders` — configurable browser hardening fields.
  Set `content_security_policy` to emit a CSP; every `{nonce}` placeholder is
  replaced with a fresh Base64URL nonce exposed through
  `weft.middleware.security_headers.nonce(ctx)`.
- `BasicAuth` — constant-time Basic credential check with a challenge response.
- `Cors` — exact-origin allow list, credential support, preflight handling,
  configured request-header validation, and `Vary: Origin` on every response
  (including rejected and origin-less requests); preflights also vary on
  `Access-Control-Request-Method`/`-Headers`.
- `Compress` — gzip, deflate, Brotli, and zstd negotiation from
  `Accept-Encoding` quality values (malformed or out-of-range `q` values are
  treated as unacceptable), compressible content types, and bodies above
  `min_bytes`; streamed bodies use concatenated gzip members or continuous
  deflate/Brotli/zstd encoder state, depending on the negotiated coding.
  Existing `Content-Encoding`, `no-transform`, and refused identity are
  respected.
- `recover` — converts an uncommitted handler failure into the status dispatch
  would emit (`400`/`413`/`415`/`500`), or marks a committed partial response
  `Connection: close`.
- `Etag` — content-derived `ETag` for buffered `200` responses, answering
  `If-None-Match` with `304`. Register it outside `Compress` so the tag covers
  the final encoded representation. Set `max_stream_bytes` to buffer a
  streamed response up to that bound and hash it; unknown-length streams stay
  streaming and keep no ETag.
- `Cache` — bounded in-memory GET cache. It skips authenticated requests,
  `Set-Cookie`, and `Vary` responses, honors `Cache-Control: max-age`, and
  clears on unsafe methods. Configure `max_entries`, `max_bytes`, and
  `default_ttl`.
- `AltSvc` — advertises an HTTP/3 endpoint (`Alt-Svc: h3=":443"; ma=86400` by
  default) on HTTP/1.1 and HTTP/2 responses, and skips the header when the
  request already arrived over HTTP/3.
- `Metrics` — lock-free total, active, status-class, and latency counters with a
  `snapshot()` API for health or metrics endpoints. Handler errors are
  classified with the same status mapping dispatch uses, and canceled requests
  are excluded from status classes. `snapshot().writePrometheus(writer, name)`
  renders the Prometheus text format; the namespace is validated to prevent
  exposition injection.
- `RateLimit` — bounded per-client token buckets keyed by the peer IP address
  without the ephemeral port (IPv4-mapped IPv6 shares the IPv4 key), with `429`
  and `Retry-After`, fixed storage, and least-recently-seen eviction.
  `Options.key_header` keys buckets on a hashed request header instead (for
  example an API key), falling back to the peer address when it is absent.
  Reverse-proxy deployments must apply their own trusted-forwarded-address
  policy.

Parameterized middleware uses a user-owned context:

```zig
var auth = weft.middleware.BasicAuth{
    .username = "admin",
    .password = "secret",
};
try router.get("/admin", admin, .{ .middleware = &.{auth.handler()} });
```

## Logging

`weft.logging.AccessLog` emits one typed [kron](../../../kron) event per request. It
is a normal middleware handler and should run after `requestId`:

```zig
const kron = @import("kron");

const logging = try kron.Logging.create(allocator, io, .{
    .outputs = &.{.{
        .name = "stdout",
        .target = .stdout,
        .mode = .sync,
        .format = .json,
    }},
});
defer logging.destroy();

var access = weft.logging.AccessLog{ .logging = logging };
const common = [_]weft.Handler{
    weft.handler(weft.middleware.requestId),
    access.handler(),
};

var server = try weft.Server(App).init(
    io,
    allocator,
    .{ .address = .{ .ip4 = .loopback(8080) }, .middleware = &common },
    .{},
);
```

Each event carries `request_id`, `method`, `path`, `query`, `status`,
`duration_ns`, `protocol`, `remote`, and `err` (empty on success). The level
defaults to `.info`; set `AccessLog.level` to change it.

Calling `kron.setGlobalLogging(logging)` with the same owner also routes
weft's internal server diagnostics, and netz's HTTP/1 serve-loop error
observer, through kron. Without a global owner those diagnostics fall back to
`std.log`. `weft.logging.logf`, `logWarn`, `logErr`, `logInfo`, and
`logDebug` expose the same fallback-aware helper for application code.
`zig build run-logging` starts the structured logging example. See
[docs/logging.md](../logging.md) for the measured producer cost and the
kron design evaluation.

