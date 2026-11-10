# Limits and lifecycle

Every request budget, the connection/worker bounds, and the cooperative
shutdown sequence.

[Back to the documentation index](../README.md)

## Limits

`weft.Limits` maps Netz's HTTP/1 limits and adds weft-owned budgets:

- `max_head_bytes`, `max_request_headers`, and `max_request_target_bytes`
  bound the request head, field count, and target on every adapter. HTTP/1 and
  HTTP/2 enforce them in Netz; the HTTP/3 adapter additionally checks the
  non-pseudo field count, QPACK field-section size, and target length before
  converting headers. Over-budget requests receive `431` or `414`.
- `max_body_bytes` bounds decoded request bodies on every adapter. Buffered
  reads and streaming `BodyReader` pulls share the same effective budget, so a
  handler cannot read past it; `RouteOptions.max_body_bytes` lowers it per
  route.
- `max_request_arena_bytes` bounds per-request headers, bodies, params,
  decoded query values, response headers, and middleware locals. HTTP/1,
  HTTP/2, and HTTP/3 adapters all enforce it with a fixed arena.
- `max_response_bytes` rejects oversized buffered bodies before they are
  written and bounds the bytes produced by streaming bodies.
- `max_response_headers` and `max_response_head_bytes` bound the response head
  independently of the body. Weft reserves head room for `Content-Length`,
  `Date`, and `Connection` fields that Netz may add, so the configured budget
  describes the complete wire head. Header names and values are validated and
  copied into the response arena; CR/LF injection is rejected.
- `max_middleware` bounds the combined server/group/route middleware chain.
- `max_query_params` bounds decoded query pairs.
- `max_multipart_parts` bounds `multipart/form-data` parts.
- `max_streaming_window_bytes` bounds the copy window used to stream request
  bodies to a handler task; the protocol layer still enforces
  `max_body_bytes` on the total body. HTTP/2 and HTTP/3 use the same value,
  capped at 16 KiB per read by their stack window.
- `max_http2_concurrent_streams` bounds simultaneously open HTTP/2 request
  streams per connection (default 16), limiting buffered DATA and concurrent
  handler tasks.
- `max_http2_frame_payload` bounds the local HTTP/2 frame payload allocation
  ceiling (default 1 MiB).
- `http2_enable_connect_protocol` advertises RFC 8441 extended CONNECT so
  WebSocket routes can run over HTTP/2.
- `request_timeout` optionally races the handler/middleware chain against a
  timer. On expiry the chain is canceled at its next cancellation point and the
  request returns `503`. CPU-bound handlers with no cancellation point cannot be
  preempted.
- `max_connections` bounds concurrent connections through the worker count.
- `max_requests_per_connection` bounds persistent HTTP/1 reuse.

## Lifecycle

`Server.deinit` must not run while `serve` is active. The normal order is:

1. run `serve` in a task or thread;
2. call `server.stop()`;
3. await the serving task;
4. call `server.deinit()`.

`stop()` is cooperative: idle workers stop accepting within
`accept_poll_interval`, in-flight requests finish, and subsequent responses
carry `Connection: close`. `serve` waits for workers to drain before returning.
`Options.drain_timeout` bounds that wait; on expiry the worker group is
cancelled at its next cancellation point. A connection blocked waiting for a
subsequent keep-alive request is bounded by `request_head_timeout` (30 seconds
by default). A handler that never reaches a cancellation point still holds its
worker; fully preemptive cancellation is not part of this slice.

Register routes before calling `serve`. Matching is read-only, but registration
itself is not synchronized with in-flight requests.

