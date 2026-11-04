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

`respondAndDrain` writes the status with `Connection: close`, then calls
`Connection.drainAndClose(deadline)` from netz (`a1d53bdc`). The deadline is
`error_drain_timeout = 250 ms`; netz separately caps discarded bytes at
64 KiB. This half-closes the write side first so the peer sees the response
and EOF before the close.

Errors from `readRequestBodyWithBuffer` are now mapped through
`statusForReadError` instead of bubbling out and closing with no response.
That covers head-stage rejections such as `431` and `414`, which happen before
a reader is returned.

## Upstream gap (filed with netz)

`Connection.writeResponse` begins with `writer_state.ensureAvailable()`. After
`RequestBodyReader`'s producer calls `writer_state.failRead()`, the phase is
`.unusable`, so the error response write is refused with
`error.ConnectionUnusable` and the client sees only EOF. This affects every
reader-surfaced status (`400/408/413/414/431`).

Weft has the status mapping and drain wiring ready. Netz needs a
post-read-failure write path; the request is recorded in
`../netz/docs/weft-integration-requests.md` section 6, with the preferred
shape `Connection.respondAndClose(response, deadline)`. Once available, weft's
`respondAndDrain` should call that API and the end-to-end 431/414 package test
should be restored.

## Verification

```sh
cd /home/passchaos/project-z/weft
zig build test --global-cache-dir /tmp/weft-zig-global --summary all
zig build test -Doptimize=ReleaseFast --global-cache-dir /tmp/weft-zig-global --summary all
zig build examples --global-cache-dir /tmp/weft-zig-global --summary all
```

Results at this slice:

- Debug: 144/144 tests passed (101 unit + 43 package).
- ReleaseFast: 144/144 tests passed.
- Examples: build succeeded.

New package tests:

- `package: Unix socket server serves HTTP/1` — starts `weft.Server` with
  `.unix_path` in a temporary directory, checks `ipAddress() == null` and
  `unixPath()`, then performs a real GET through
  `netz.http1.runtime.Client.connectUnix`.
- `package: server requires exactly one listen address` — asserts
  `error.InvalidOptions` for neither and both address forms.

The earlier `statusForReadError` unit test remains in `src/server.zig`.

## Limits

- Unix sockets are HTTP/1 cleartext only. HTTP/2 and HTTP/3 adapters still take
  a TCP address.
- The 250 ms drain budget is per error response and runs on the owning worker;
  it is bounded by `max_connections`.
- Protocol-error responses remain dependent on the netz write path described
  above.
