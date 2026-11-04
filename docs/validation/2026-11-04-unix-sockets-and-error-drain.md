# Unix sockets and HTTP/1 error-response drain

Date: 2026-11-04

## Scope

1. Serve HTTP/1 over a Unix-domain stream socket through `weft.Server`.
2. Route HTTP/1 protocol-error responses through a bounded
   drain-before-close path instead of closing with unread request bytes.

Both changes stay inside weft's application adapter. Unix socket parsing,
accept, and connection state remain in `netz.http1.runtime`; weft only selects
the listener and validates options.

## Unix socket support

`Server.Options` now accepts exactly one of:

- `address: ?std.Io.net.IpAddress` (TCP, the previous behavior), or
- `unix_path: ?[]const u8` (Unix-domain stream socket).

`Server.init` returns `error.InvalidOptions` when both or neither are set, and
also when `unix_path` is combined with `tls` (TLS over a Unix socket is not
supported by the adapter).

Accessors:

- `server.address()` keeps its old `IpAddress` return type and panics for a
  Unix server.
- `server.ipAddress()` returns `?IpAddress` (`null` for Unix).
- `server.unixPath()` returns the configured path (`null` for TCP).

The socket file is caller-owned. Netz's `UnixServer.deinit` closes the
listener but does not unlink the path.

## HTTP/1 error-response drain

`serveConnection` now returns a three-state `Disposition` instead of `bool`:

- `.close` — close immediately;
- `.drained` — `respondAndDrain` already wrote the response, drained bounded
  input, and closed;
- `.upgraded` — a WebSocket took ownership of the socket.

`respondAndDrain` calls `Connection.respondAndClose(response, deadline)` from
netz. That API permits the final write even after the request read marked the
connection unusable, forces `Connection: close`, half-closes the write side so
the peer sees the response and EOF, drains bounded input, and closes. The
deadline is `error_drain_timeout = 250 ms`; netz separately caps discarded
bytes at 64 KiB.

Errors from `readRequestBodyWithBuffer` are now mapped through
`statusForReadError` instead of bubbling out and closing with no response.
That covers head-stage rejections such as `431` and `414`, which happen before
a reader is returned.

## Post-read-failure write

`Connection.writeResponse` begins with `writer_state.ensureAvailable()`. After
`RequestBodyReader`'s producer calls `writer_state.failRead()`, the phase is
`.unusable`, so a plain error-response write is refused with
`error.ConnectionUnusable`. `Connection.respondAndClose` is the netz API that
solves this: it bypasses the availability check (the connection will not be
reused), writes the response, drains, and closes. Weft uses it for every
reader-surfaced status (`400/408/413/414/431`).

## Verification

```sh
cd /home/passchaos/project-z/weft
zig build test --global-cache-dir /tmp/weft-zig-global --summary all
zig build test -Doptimize=ReleaseFast --global-cache-dir /tmp/weft-zig-global --summary all
zig build examples --global-cache-dir /tmp/weft-zig-global --summary all
```

Results at this slice:

- Debug: 145/145 tests passed (101 unit + 44 package).
- ReleaseFast: 145/145 tests passed.
- Examples: build succeeded.

New package tests:

- `package: Unix socket server serves HTTP/1` — starts `weft.Server` with
  `.unix_path` in a temporary directory, checks `ipAddress() == null` and
  `unixPath()`, then performs a real GET through
  `netz.http1.runtime.Client.connectUnix`.
- `package: server requires exactly one listen address` — asserts
  `error.InvalidOptions` for neither and both address forms.
- `package: oversized request head and target return 431 and 414` — sends a
  head over `max_head_bytes` and a target over `max_request_target_bytes`
  through a real client, asserting the protocol status survives the close.

The earlier `statusForReadError` unit test remains in `src/server.zig`.

## Limits

- Unix sockets are HTTP/1 cleartext only. HTTP/2 and HTTP/3 adapters still take
  a TCP address.
- The 250 ms drain budget is per error response and runs on the owning worker;
  it is bounded by `max_connections`.
