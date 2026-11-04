# HTTP/2 suppressed responses and bounded trailers

Date: 2026-11-04

## Scope

Three application-layer fixes found while re-auditing the adapter and middleware
paths against `AGENTS.md`:

1. Trailer lookup must not weaken the request-body budget.
2. HTTP/2 must not write DATA after a HEAD/204/304 response head ended the
   stream, and a buffered HEAD response must preserve its representation length.
3. Streamed compression must answer `406` when the client refuses identity and
   accepts no supported coding.

## Trailer lookup keeps the body reader bounded

`Ctx.trailers()` used to replace `body_reader` with its inner reader when the
current reader was a `LimitedReader` (per-route body budget) or a
`DecodedReader` (incremental `Content-Encoding`). A handler that inspected
trailers before reading the body therefore lost the route budget or decoder and
could read past the configured bound on HTTP/2 and HTTP/3.

`Ctx` now resolves a read-only transport view for trailer lookup. The view
peels `.limited` and `.decoded` wrappers without replacing `body_reader`, so
subsequent `readBody()`, `bodyReader()`, and `decodedReader()` calls keep the
same limits and decoder state.

Unit test: `trailer lookup keeps the bounded reader intact` in `src/ctx.zig`.

## HTTP/2 HEAD/204/304 responses

Netz's `startResponse` ends the stream in the response head for HEAD, 204, 304,
and 1xx responses. Weft then issued `writeData`/`finish` for the suppressed
body, which targeted a finished stream and produced an avoidable
`ConnectionClosed` error and stream reset after a valid response.

The HTTP/2 adapter now returns immediately after `startResponse` for
body-forbidden responses. It also derives `Content-Length` from the buffered
body for HEAD when the handler did not set one, matching the existing streamed
HEAD and HTTP/3 behavior.

Package tests:
- `package: HTTP/2 adapter serves routes, errors, and streams` sends HEAD to a
  buffered JSON route and asserts an empty body with the GET representation
  length.
- `package: HTTP/3 adapter serves routes, POST, and streams` does the same over
  HTTP/3.
- The existing streamed HEAD checks remain.

## Streamed compression and refused identity

`Compress` answered `406` for buffered responses when identity was refused, but
returned the stream unchanged when the response was incremental. The stream
path now cancels the producer, resets the response, and emits `406` with
`Vary: Accept-Encoding`, matching the buffered path.

Unit test: `compress middleware returns 406 for streamed bodies when identity
is refused` in `src/middleware/compress.zig`.

## Streaming multipart boundary prefixes at window edges

`multipartStream` treated a `\r\n--boundary` occurrence at the end of its
fixed window as a delimiter without checking the following byte. A payload
containing `\r\n--boundaryX` (where `X` is not `\r` or `-`) could therefore be
truncated when the window ended exactly after the boundary text. The same
ambiguity existed while scanning the preamble for the initial delimiter.

The parser now keeps an ambiguous candidate in the window, returns only the
safe prefix before it, and fills more bytes before deciding. The initial
delimiter is also accepted only when followed by CRLF or `--`.

Tests in `src/multipart_stream.zig`:
- `streaming multipart keeps a boundary prefix at the window edge`
- `streaming multipart keeps a boundary prefix in the preamble`

## If-Range date comparison

RFC 9110 §13.1.5 requires an `If-Range` date validator to match the
representation's `Last-Modified` value exactly. The static-file handler used
`last_modified <= date`, so a future date incorrectly allowed a partial
response. The comparison is now exact, and the precondition test covers a date
newer than the representation.

## Request-body arena exhaustion

Buffering a request body into the fixed per-request arena could surface
`OutOfMemory` as a `500` when the body fit `max_body_bytes` but not
`max_request_arena_bytes`. `Ctx.readBody()` and the HTTP/3 buffered-body path
now treat arena exhaustion while copying body bytes as `error.PayloadTooLarge`,
so the request receives `413` and the connection stays usable.

Unit test: `readBody maps arena exhaustion to PayloadTooLarge` in
`src/ctx.zig`.

## Empty Accept negotiation

`Ctx.accepts()` treated an empty `Accept` field value as accepting anything,
but `Ctx.preferredType()` returned null for the same header. Both now treat an
absent or empty field value as `*/*`, so a handler cannot see a 406-worthy
preference from an empty header.

## HTTP/2 buffered request bodies

Non-streaming HTTP/2 routes previously always received a streaming reader, so
`Ctx.body()` was empty even though the route had not opted into streaming.
The adapter now buffers a request with a declared non-zero `Content-Length`
into the request arena and passes no reader, matching the HTTP/1 and HTTP/3
buffered-route behavior. A declared zero length yields an empty body without
waiting for DATA and still exposes any request trailers.

Requests without a declared length keep the streaming reader: netz's
concurrent engine publishes body completion only while draining a stream, so a
bodyless request with no DATA frames cannot be read to completion from the
handler. Those handlers must use `Ctx.readBody()` / `Ctx.bodyReader()` as
before. The protocol-level follow-up is tracked as item 8 in
`netz/docs/weft-integration-requests.md`.

Package test: the HTTP/2 adapter test posts to `/body-echo` and asserts that a
non-streaming handler sees the buffered body through `Ctx.body()`.

## HTTP/1 absolute-form request targets

Netz accepts and validates absolute-form HTTP/1 targets and makes the target
authority authoritative for `Host`, but weft's router previously received the
whole `http://host/path` string and returned `404`. `src/target.zig` now
splits origin-form and absolute-form targets into path and query for both the
streaming-route check and dispatch. `ctx.target()` still returns the original
wire target.

Tests:
- `target splitting handles origin and absolute forms` in `src/target.zig`
- `package: HTTP/1 routes an absolute-form request target` sends a raw
  `GET http://example.com/hello/absolute HTTP/1.1` and asserts the route runs.

## Verification

```sh
zig fmt --check src test bench examples build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
```

Results: 159/159 tests in Debug and ReleaseFast (107 unit, 52 package).
