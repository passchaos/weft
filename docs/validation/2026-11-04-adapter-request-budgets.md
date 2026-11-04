# Adapter request-budget parity

Date: 2026-11-04

## Problem

`Limits.max_request_target_bytes`, `max_request_headers`, and `max_head_bytes`
were enforced by Netz for HTTP/1, and by Netz's header-list limits for HTTP/2,
but the HTTP/3 adapter only inherited the reassembled stream buffer
(`max_body_bytes + max_head_bytes`). A request with a very long `:path`, many
fields, or a large QPACK field section could therefore pass the HTTP/3 adapter
even when the same `Limits` rejected it on HTTP/1. The HTTP/2 adapter also did
not apply `max_request_target_bytes`, which Netz does not check for `:path`.

## Change

- HTTP/2 `serveConcurrentStream` rejects a target longer than
  `max_request_target_bytes` with `414 URI Too Long` before converting headers
  or running the router.
- HTTP/3 `serveConcurrentStream` performs the same target check, plus:
  - counts non-pseudo header fields and rejects more than
    `max_request_headers` with `431`;
  - computes the QPACK field-section size as
    `name.len + value.len + 32` per field (including the synthesized `host`
    when `:authority` is present) and rejects more than `max_head_bytes`
    with `431`.
- Both adapters answer through a small `rejectConcurrent` helper that builds
  the response in the request arena and uses the existing concurrent writer,
  so no router or middleware runs for a rejected request.

The checks use saturating arithmetic, so a hostile field list cannot overflow
the budget computation.

## Request-body budget

`dispatch` previously wrapped a streaming reader in `LimitedReader` only when a
route lowered `max_body_bytes`. HTTP/1's Netz pull reader enforces the
server-wide budget itself, but the HTTP/2 concurrent stream reader and the
HTTP/3 stream reader do not, so a streaming handler could read past the
server-wide limit. `dispatch` now always wraps the effective reader with
`effective_limits.max_body_bytes`, and `toHttp3Netz` forwards
`max_body_bytes` to Netz's HTTP/3 stream accounting.

A new HTTP/2 package test sets the server budget to 4 KiB and the route budget
to 1 KiB, uploads 2 KiB, and expects `413`.

## Upstream note

When a request's declared `Content-Length` exceeds the server-wide HTTP/2
budget, Netz currently fails the whole connection with `MessageTooLarge`
instead of surfacing a stream-level error, so weft cannot turn it into a
`413` on that stream. The request for stream-level handling is tracked in
`netz/docs/weft-integration-requests.md` section 7; per-route budgets already
return `413`.

## Verification

```sh
cd /home/passchaos/project-z/weft
zig build test --global-cache-dir /tmp/weft-zig-global --summary all
zig build test -Doptimize=ReleaseFast --global-cache-dir /tmp/weft-zig-global --summary all
zig build examples --global-cache-dir /tmp/weft-zig-global --summary all
```

Results at this slice:

- Debug: 150/150 (101 unit + 49 package).
- ReleaseFast: 150/150.
- Examples: build succeeded.

Coverage:

- `package: HTTP/2 rejects an over-long request target` drives a real h2c
  client with `max_request_target_bytes = 32` and expects `414`.
- The existing HTTP/3 package test now sets the same 32-byte target budget and
  sends a 64-byte path, expecting `414`. Its other paths stay below the budget.
- `package: HTTP/2 per-route body budget returns 413` covers the streaming
  body wrapper.
- HTTP/1 keeps its end-to-end `431`/`414` coverage from the error-response
  slice.

## Limits

- The HTTP/3 field-section check runs after QPACK decoding, so the decoded
  field list is already bounded by the reassembled stream buffer. The check
  converts an over-budget request into the correct status instead of an
  arena-allocation failure or a generic `500`.
- HTTP/2 header count and list size remain enforced by Netz; weft only adds
  the `:path` budget.
