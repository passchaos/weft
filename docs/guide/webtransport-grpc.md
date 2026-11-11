# WebTransport and gRPC

WebTransport sessions over QUIC/HTTP/3, and unary gRPC services over HTTP/2.

[Back to the documentation index](../README.md)

## WebTransport

`weft.WebTransportServer(H)` wraps netz's QUIC/TLS WebTransport runtime. It
accepts one WebTransport session per QUIC connection, dispatches by exact
CONNECT path, and exposes datagrams and streams through a concrete `Session`.

```zig
const App = struct {};

fn echo(_: *App, session: *weft.WebTransportSession) anyerror!void {
    var datagram_storage: [1200]u8 = undefined;
    const datagram = try session.receiveDatagramWithTimeout(
        &datagram_storage,
        .fromSeconds(5),
    );
    try session.sendDatagram(datagram);

    var stream = try session.receiveStreamWithTimeout(.fromSeconds(5));
    defer stream.deinit();
    try session.sendStream(stream.streamId(), stream.payload(), true);
}

var server = try weft.WebTransportServer(App).init(io, allocator, .{
    .address = .{ .ip4 = .loopback(9443) },
    .handshake = .{
        .local_connection_id = &server_cid,
        .random = server_random,
        .x25519_secret_key = server_secret,
    },
    .max_connections = 64,
    .max_stream_bytes = 1024 * 1024,
    .max_datagram_bytes = 64 * 1024,
}, .{});
defer server.deinit();

try server.route("/echo", echo);
try server.serve();
```

`Session` exposes:

- request metadata: `path()`, `authority()`, `origin()`, `userAgent()`,
  `headers()`, `remoteAddress()`, `peerCertificates()`,
  `applicationProtocol()`, `sessionId()`;
- datagrams: `sendDatagram`, `receiveDatagram`, `maxDatagramSize`;
- streams: `openBidirectionalStream`, `openUnidirectionalStream`,
  `sendStream`, `receiveStream`, `readStream`, `finishStream`,
  `resetStream`;
- lifecycle: `close(code, reason)` and `drain()`.

`receiveStream` returns one whole stream bounded by `max_stream_bytes`; use
`readStream` for incremental caller-buffer reads. `receiveDatagram` writes
into caller storage, so the buffer determines the receive bound.

`route` matches exact paths. Use `setFallback` for dynamic paths and parse
`session.path()` inside the handler. `serve` stops on `stop()` and drains
sessions up to `drain_timeout`.

Set `Options.session_timeout` for an absolute per-session budget. Methods
without an explicit timeout (`receiveDatagram`, `receiveStream`, `readStream`,
`sendDatagram`, `sendStream`) then use that deadline, so a stalled peer cannot
block a handler forever. Explicit `*WithTimeout` calls are capped by the same
deadline.

## gRPC

`weft.GrpcServer(H)` wraps netz's HTTP/2 gRPC runtime and dispatches unary
calls by exact method path. Cleartext h2c is the default; set `tls` for a
TLS/ALPN `h2` listener.

```zig
fn echo(_: *App, ctx: *weft.grpc.Context) anyerror!void {
    try ctx.respond(ctx.message);
}

var server = try weft.GrpcServer(App).init(io, allocator, .{
    .address = .{ .ip4 = .loopback(50051) },
    .max_message_size = 4 * 1024 * 1024,
    .max_connections = 64,
    .max_requests_per_connection = 1000,
    .idle_timeout = .fromSeconds(60),
}, .{});
defer server.deinit();

try server.route("/demo.Echo/Unary", echo);
try server.serve();
```

`Context` exposes the decoded payload (`message`), `path`, `service`,
`method`, request `headers`, `timeout`, and the negotiated
`accepted_encodings`. Responses use:

- `respond(bytes)` for an OK message;
- `respondWithOptions(netz.grpc.UnaryResponseOptions)` for metadata,
  compression, or explicit status;
- `respondStatus(status, message)` for a trailers-only non-OK result.

The adapter replies `unimplemented` when no route or fallback matches, and
`internal` when a handler fails before responding. `netz.grpc.Status` and the
message codec remain available through `weft.netz.grpc`; protobuf helpers live
in `netz.grpc.pbz`.

Limits and lifecycle:

- `max_message_size` bounds decoded request and response messages.
- `max_requests_per_connection` bounds calls per channel; the adapter sends a
  graceful GOAWAY after the limit.
- `idle_timeout` bounds a channel waiting for its next call.
- `serve` stops on `stop()` and drains connections up to `drain_timeout`.

The unary adapter handles one request/response call. For streaming RPCs use
`weft.GrpcStreamingServer(H)`: it accepts duplex streams, collects the request
messages, and exposes `nextMessage`, `write`, and `finish` through a streaming
context. This covers client-streaming and server-streaming calls; interleaved
bidirectional handlers should use netz's `ServerDuplex` directly.

Set `Options.grpc_web = true` to serve gRPC-Web framing instead of native gRPC
on that listener. `Options.cors_policy` applies to gRPC-Web preflights and
responses. Native gRPC and gRPC-Web are separate listener modes.

Calls on one connection are processed serially, matching the single mutable
HTTP/2 session state.
