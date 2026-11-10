# Server adapters

TLS, Unix sockets, HTTP/2, HTTP/3, and WebSocket upgrades. All adapters share
the same `Router`, `Ctx`, middleware chain, and `Limits`.

[Back to the documentation index](../README.md)

## TLS

Set `Options.tls` to a `netz.http1.runtime.TlsListenOptions` to serve HTTPS.
Weft applies its own `Limits` and `tcp_nodelay` to the nested TLS options, so
HTTP and TLS budgets stay consistent:

```zig
var server = try weft.Server(App).init(
    io,
    gpa,
    .{
        .address = .{ .ip4 = .loopback(443) },
        .tls = .{ .identity = identity },
    },
    .{},
);
```

TLS workers use `tls_accept_timeout` as the combined accept plus handshake
budget, which also bounds idle shutdown polling. TLS transport, ciphers,
certificate policy, and session handling remain owned by Netz.

## Unix sockets

Set `Options.unix_path` instead of `Options.address` to serve HTTP/1 over a
Unix-domain stream socket (for example behind a reverse proxy on the same
host). Exactly one of the two must be set, and TLS is rejected on Unix
sockets:

```zig
var server = try weft.Server(App).init(
    io,
    gpa,
    .{ .unix_path = "/run/weft.sock" },
    .{},
);
defer server.deinit();
```

The application surface is unchanged: routing, middleware, streaming, and
limits behave exactly as on TCP. `ctx.clientAddress()` is `null` because a
Unix socket has no IP peer (std otherwise reports a synthetic `127.0.0.1`);
with `Limits.trust_forwarded_for`, a trusted `X-Forwarded-For` header still
supplies the client address. `server.ipAddress()` returns `null` and
`server.unixPath()` returns the configured path; `server.address()` panics for
a Unix-socket server because there is no TCP address. The socket file is
caller-owned: Netz closes the listener on `deinit` but does not unlink the
path, so remove it after the server stops.

## HTTP/2

`weft.Http2Server(H)` serves cleartext prior-knowledge h2c and optional TLS
with mandatory ALPN `h2`. It reuses the same `Router`, `Ctx`, middleware,
limits, and streaming response contract:

```zig
var server = try weft.Http2Server(App).init(
    io,
    gpa,
    .{
        .address = .{ .ip4 = .loopback(8080) },
        .limits = .{ .max_body_bytes = 1024 * 1024 },
    },
    .{},
);
defer server.deinit();

try server.router().get("/hello/:name", hello, .{});
try server.serve();
```

For HTTPS, set `Options.tls` to a `netz.http2.runtime.TlsListenOptions`; Netz
requires ALPN `h2`, and weft applies its own `Limits` and `tcp_nodelay`.
`tls_accept_timeout` bounds accept, TLS setup, and the HTTP/2 bootstrap.
Set `Options.alpn_http1 = true` to negotiate `h2` and `http/1.1` on the same
TLS port; HTTP/1.1 fallback requests use the same router and middleware and
support buffered request bodies and streaming responses, but not WebSocket
upgrades or incremental request bodies.

Set `Options.h2c_upgrade = true` on a cleartext listener to accept HTTP/1.1
`Upgrade: h2c`. This mode is mutually exclusive with prior-knowledge h2c on the
same listener: every accepted connection must start with an HTTP/1.1 upgrade
request. The upgrade request (stream 1) must produce a buffered response;
subsequent streams use the normal HTTP/2 path.

Set `Options.unix_path` instead of `Options.address` to serve prior-knowledge
h2c over a Unix-domain socket, with the same exclusivity and TLS rules as the
HTTP/1 adapter. `ctx.clientAddress()` is `null` on that transport, and
`ipAddress()` / `unixPath()` report which transport is active.

Netz owns frame parsing, HPACK, flow control, and stream state. Weft maps each
completed request into the concrete `Ctx` view and maps responses back to
lowercase HTTP/2 header fields. Response streaming, `HEAD`, `404/405/OPTIONS`,
request decoding, and timeout budgets behave the same as HTTP/1.

Netz's concurrent engine owns the frame reader, HPACK state, and socket
writer. Every request runs in one of up to `max_concurrent_handlers` handler
tasks; handlers pull request DATA from bounded per-stream buffers and may
submit buffered or chunked responses with trailers. Advertised stream
concurrency is capped to the same handler bound.

Routes can opt into the bodyless inline fast path with
`RouteOptions.inline_bodyless`. When the request head already carries
END_STREAM, the handler runs on the connection owner and its buffered
response is applied in place, removing the worker handoff. Inline handlers
must produce a buffered response: `ctx.stream`, `ctx.sse`, and WebSocket
upgrades are rejected. Requests with bodies and streaming routes stay on the
worker path.

## HTTP/3

`weft.Http3Server(H)` serves HTTP/3 over QUIC/TLS with ALPN `h3`. It reuses the
same `Router`, `Ctx`, middleware, limits, decoded inputs, and streaming
response contract:

```zig
var server = try weft.Http3Server(App).init(
    io,
    gpa,
    .{
        .address = .{ .ip4 = .loopback(8443) },
        .handshake = .{
            .identity = identity,
            .local_connection_id = "weft-h3",
        },
    },
    .{},
);
defer server.deinit();

try server.router().get("/hello/:name", hello, .{});
try server.serve();
```

Netz owns QUIC handshake, TLS, stream parsing, QPACK, flow control, and
recovery. Weft maps each completed request into `Ctx` and maps responses back
to lowercase HTTP/3 fields. `quic_limits`, `max_concurrent_streams`,
`max_concurrent_handlers`, and `accept_timeout` bound transport, admission, and
handler concurrency.

Each session runs up to `max_concurrent_handlers` handler tasks concurrently
through netz's owner-serialized concurrent engine. Handlers pull request DATA
incrementally with `Ctx.bodyReader()` (`.h3_stream`) while netz bounds the
resident per-stream window with `max_streaming_window_bytes` and enforces
`max_body_bytes` on the whole body. The advertised request-stream concurrency
is capped to `min(max_concurrent_streams, max_concurrent_handlers)`.

Routes can opt into the bodyless inline fast path with
`RouteOptions.inline_bodyless`. When the request head already ends the stream,
the handler runs on the QUIC owner and its buffered response is applied in
place; request bodies and streaming routes keep the worker path.

## WebSockets

`ctx.upgradeWebSocket(...)` selects an RFC 6455 session on HTTP/1.1 and on
HTTP/2 extended CONNECT (RFC 8441). Weft validates the opening handshake,
writes `101 Switching Protocols` on HTTP/1.1 or `200` on HTTP/2, and runs the
session synchronously on the connection worker. Set
`Limits.http2_enable_connect_protocol = true` for HTTP/2. HTTP/3 extended
CONNECT currently returns `400` until netz exposes a dedicated accept path:

```zig
fn wsEcho(_: ?*anyopaque, session: *weft.WebSocketSession) anyerror!void {
    var message = try session.receiveMessage();
    defer session.deinitMessage(&message);
    try session.sendText(message.payload);
}

fn ws(app: *App, ctx: *weft.Ctx) anyerror!void {
    _ = app;
    try ctx.upgradeWebSocket(.{ .run_fn = wsEcho });
}
```

The session exposes text/binary sends, ping/pong control frames,
frame/message reads with `deinitMessage`, and explicit `sendClose(code, reason)`.
`close()` sends a normal closure frame when one has not already been written
and then releases the transport. An optional `subprotocol` must be offered by
the client. Set `.compression = true` to negotiate RFC 7692
`permessage-deflate`; the accepted parameters are echoed in
`Sec-WebSocket-Extensions` and messages at or above
`compression_threshold` bytes (default 32) are compressed. HTTP/3 rejects WebSocket upgrades with `400`; HTTP/2 uses RFC 8441 extended
CONNECT and does not negotiate `permessage-deflate` in this slice.

