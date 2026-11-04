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

## Verification

```sh
zig fmt --check src test bench examples build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
```

Results: 156/156 tests in Debug and ReleaseFast (105 unit, 51 package).
