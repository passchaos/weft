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
waiting for DATA; trailers are copied when the concurrent engine has already
published them.

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

## Empty multipart forms

The buffered `Ctx.multipart()` parser rejected a form with no parts while the
incremental `Ctx.multipartStream()` parser accepted it. Both now return an
empty form for a closing delimiter with no parts.

Unit test: `multipart accepts an empty form` in `src/multipart.zig`.

## Cached streaming body

`Ctx.readBody()` caches a streaming request body in the arena, but `Ctx.body()`
still returned only the adapter-provided `request.body` slice. `body()` now
returns the cached bytes when `readBody()` has already consumed the stream, so
the two accessors stay coherent.

Unit test: `body returns the cached streaming body` in `src/ctx.zig`.

## Streamed compression chunk bound

Streamed gzip compression copied each producer chunk into a fresh compressed
allocation before the transport writer enforced `max_response_bytes`. A
producer that wrote a chunk larger than the response budget could therefore
cause an oversized intermediate allocation. `ChunkCompress` now rejects such a
chunk with `error.ResponseTooLarge` before compressing it.

Unit test: `compress middleware bounds one streamed chunk` in
`src/middleware/compress.zig`.

## Non-positive timeout budgets

`Limits.request_timeout`, `Limits.request_head_timeout`,
`Options.accept_error_backoff`, and the HTTP/3 recovery drain budget are now
validated as positive durations at `init`. Previously a zero or negative value
was accepted and could turn every request or accept loop iteration into an
immediate timeout. `max_request_target_bytes = 0` and an explicitly zero
`max_http2_concurrent_streams` are rejected for the same reason: they make the
adapter unusable. HTTP/2 also rejects a `max_concurrent_handlers` value that
does not fit Netz's 32-bit stream limit.

Package test: `package: servers reject unusable option budgets` covers HTTP/1,
HTTP/2, and HTTP/3 initialization.

## HTTP/2 and HTTP/3 streaming routes with query strings

Both concurrent adapters passed the whole `:path` value to
`Router.isStreaming`, including the query string. A route registered with
`RouteOptions.streaming` therefore looked non-streaming whenever the request
carried a query: HTTP/2 buffered the body and HTTP/3 read it eagerly, so
`Ctx.bodyReader()` was null and `Ctx.multipartStream()` failed with
`NotStreamingRoute`.

Both adapters now split the target with `target.split` and match on the path,
matching the HTTP/1 adapter and `dispatch`. The regression test registers a
streaming route that reports whether it received a reader and requests it with
`?check=1` over both HTTP/2 and HTTP/3.

## Fallback body budget

`dispatch` wrapped the adapter's body reader in `LimitedReader` only when the
route resolution succeeded. A custom `not_found`, `bad_request`, or
`method_not_allowed` handler that used `Ctx.bodyReader()` directly could
therefore read past `Limits.max_body_bytes` on HTTP/2 and HTTP/3, whose stream
readers do not enforce the budget themselves. The wrapper is now applied for
every request with a streaming reader, including fallback handlers.

The wrapper is a stack local in `dispatch`, so applying the budget costs no
arena allocation.

Unit test: `fallback handlers keep the streaming body bounded` in
`src/dispatch.zig`.

## Indexed rate-limit buckets

`RateLimit` located a client bucket by scanning the fixed table, and picked an
eviction victim with a second scan. With the default 4096 clients, a busy
server paid an O(clients) comparison cost per request. A bounded
`AutoHashMapUnmanaged` index now maps each key to its bucket slot; capacity is
reserved in `init`, and evicting the least-recently-seen client removes its key
before the slot is reused. Lookup and insertion are O(1) and the table remains
fixed-size.

Unit test: `rate limit index tracks evicted buckets` in
`src/middleware/rate_limit.zig`.

## Multipart boundary candidates

Both multipart parsers treated any `\r\n--boundary` occurrence followed by a
bare CR or a single `-` as a delimiter line. Such bytes are valid part data;
RFC 2046 only starts a delimiter line at `--boundary--` (closing) or
`--boundary` followed by a complete CRLF. The buffered parser now requires the
full trailing sequence. The streaming parser reports an incomplete candidate
when the deciding byte is not buffered yet and keeps scanning otherwise, so a
window edge cannot turn payload into a delimiter.

The streaming parser also ignores empty source chunks instead of reporting
progress that would spin the caller.

Tests:
- `multipart keeps a boundary-like line with a bare CR` and
  `multipart keeps a single-dash boundary candidate as data` in
  `src/multipart.zig`.
- The streaming equivalents plus `streaming multipart ignores empty source
  chunks` in `src/multipart_stream.zig`.

## Streamed gzip scratch reuse

`StreamCompress` compressed every producer chunk into a fresh arena
allocation. `std.Io.Writer.Allocating` growth leaked its intermediate buffers
into the fixed request arena, so a long streamed gzip response could exhaust
`max_request_arena_bytes` even though the transport budget was respected. The
wrapper now compresses fixed 16 KiB slices into one reusable output buffer
allocated when the stream is selected; a final empty member keeps the stream
valid.

If the request arena cannot provide the encoder state or scratch buffer, the
middleware leaves the response uncompressed instead of failing it.

Unit test: `compress middleware streams gzip within a small arena` in
`src/middleware/compress.zig` streams 256 KiB through a 64 KiB arena.

## Single route lookup per request

Every adapter previously walked the route trie twice: once through
`Router.isStreaming` before reading the body, and again inside `dispatch`.
`Router.prepare` now resolves the route, captures, and allowed methods without
allocating; the adapter uses `prepared.route.streaming` for the body decision
and passes the same value to `dispatch`, which builds the match from the
captured values. `resolve` and `isStreaming` keep their existing
allocation-free implementations for direct callers.

The HTTP/1 adapter also allocates its per-request arena on the first request
instead of at connection accept, so idle keep-alive connections do not reserve
`max_request_arena_bytes`.

## ETag and non-GET methods

The `Etag` middleware turned any matching `If-None-Match` into `304`, even for
`POST`, `PUT`, or `DELETE` responses whose handler had already run. RFC 9110
§13.1.2 only defines that short-circuit for `GET` and `HEAD`; other methods now
keep their response (and still receive the computed `ETag`).

Unit test: `etag middleware keeps non-GET responses intact` in
`src/middleware/etag.zig`.

## HTTP/2 and HTTP/3 header conversion

Both adapters lowercased every response field name into a fresh arena
allocation. An already-lowercase name now borrows the response-owned copy, and
the field array is sized once before conversion. This removes one allocation
per header on the concurrent response paths.

## Entity tags containing commas

`strongMatches` and `weakMatches` split `If-Match` and `If-None-Match` on every
comma, so a valid quoted entity-tag such as `"a,b"` was never compared as a
whole. A small entity-tag iterator now treats commas inside a quoted tag as
part of the tag and leaves malformed tokens to the existing comparisons.

Unit test: `precondition entity tags may contain commas` in
`src/precondition.zig`.

## HTTP/3 response head

`respondConcurrent` built a full `netz.http3.Response` (including a trailer
field list) and then discarded the body and trailers before writing them
separately. The head is now constructed directly with only the header fields,
removing the redundant trailer allocation.

## Rate-limit arithmetic

Token refill uses saturating addition, and the elapsed-time multiplication uses
a widened intermediate, so extreme `max_requests` or clock-jump values cannot
overflow.

## Static MIME lookup

`StaticFiles.contentType` scanned the default MIME table linearly for every
served path. The default table now compiles to a `StaticStringMap`; the
extension is ASCII-lowercased into a 16-byte stack buffer before lookup.
Custom tables keep the case-insensitive linear scan.

Unit test: `static mime lookup handles case and custom tables` in
`src/static_files.zig`.

`normalizePath` also returns the arena-owned request path unchanged when it is
already plain (no empty, dot, hidden, or invalid segments), avoiding the
segments array and joined copy for the common case.

Unit test: `static path normalization borrows plain relative paths`.

## Borrowed path parameters

`decodeParams` allocated a decoded copy for every captured path value, even
when the value had no escapes. `query.decodeComponentBorrowed` validates the
component and returns the request-owned slice unchanged when no rewrite is
needed; path captures and the manual `Ctx.queryParam` fallback use it.

Unit test: `borrowed component decoding avoids allocation without escapes` in
`src/query.zig`.

## Invalid chunk framing

`statusForReadError` did not map `error.InvalidChunk` (a malformed chunk
extension) to a protocol status, so the HTTP/1 adapter closed the connection
without sending a `400`. It now maps to `400` alongside the other malformed
framing errors.

## Cached capture names

`buildMatch` re-scanned the registered pattern to recover `:param` and `*`
names on every parameterized match. Each route now stores its capture names at
registration and the match copies them directly. Router benchmark (ReleaseFast)
moves from ~92 ns to ~56 ns per parameterized lookup.

## Single-child trie fast path

Most trie nodes have exactly one static child, so matching hashed each segment
for nothing. A node with one child now stores its key and child inline and
compares directly; adding a second child promotes the pair into the hash map.
Router benchmark (ReleaseFast): static ~53 ns to ~47.5 ns, parameterized
~60 ns to ~55.7 ns.

## Zero-allocation parameter dispatch

`dispatch` built a `Match` (allocating the raw parameter array) and then
allocated a second decoded array for the same captures. It now decodes the
prepared captures directly into a fixed `max_params` stack array using the
route's cached names, so a parameterized request allocates nothing for path
parameters unless a value needs percent decoding. The public `resolve`/`match`
API still returns an allocated `Match` for callers that need one.

## Handler thread cap

Both concurrent adapters expose `max_handler_threads`, forwarded to Netz's
`max_worker_threads`. Null keeps one worker per possible concurrent handler;
zero is rejected. This lets a deployment trade handler parallelism against
thread-scheduling contention without changing the default.

## Status code range

`Response.setStatus` accepted any three-digit code from 100 to 999, although
HTTP only defines the 1xx-5xx classes. Codes outside 100-599 now become `500`
before they reach the wire encoder.

Unit test: `response rejects out-of-range status codes` in
`src/response.zig`.

## Route middleware without concatenation

`dispatch` allocated a combined middleware array for every request to a route
with route middleware. `Ctx` now carries `middleware` and `route_middleware`
as separate slices and `next()` walks them in order. The `max_middleware`
check still sums both, and route middleware is skipped when a disposition
fallback replaces the handler, matching the previous behavior.

Package test: `package: route middleware runs after application middleware`
asserts the order `a`, `r`, `h`.

## Inline request locals

`Locals` used a `StringHashMapUnmanaged` that allocated on the first
`ctx.set`. It now stores up to `max_locals` (16) key/value pairs inline and
scans them; `put` replaces an existing key and returns `error.TooManyLocals` at
the bound. The common one-or-two locals need no allocation.

Unit test: `locals replace values and stay bounded` in `src/ctx.zig`.

## Stack-formatted ETag

The `Etag` middleware allocated the quoted tag and its weak prefix in the
arena before `setHeader` copied the value again. It now formats both into
stack buffers, leaving `setHeader` as the single arena copy.

## Request-id allocation

`requestId` generated the id in the arena and then had `setHeader` copy it
again. It now formats the id on the stack, sets the header, and stores the
header's arena copy in the local, removing one allocation per generated id.

Unit test: `request id middleware stores the response copy` in
`src/middleware/request_id.zig`.

## Streaming readBody staging

`Ctx.readBody` grew its accumulation buffer inside the fixed request arena.
`ArrayList` growth cannot reclaim intermediate blocks from a bump allocator,
so a body that fit `max_request_arena_bytes` could still exhaust the arena.
The body is now staged in `request_allocator` and copied into the arena once;
manually constructed contexts without a server allocator keep the arena path.

Package test: `package: HTTP/2 readBody survives a small request arena` sends
6000 bytes in 512-byte chunks against an 8 KiB arena.

## JSON response staging

`Response.json` serialized through a growing arena buffer; a bump allocator
cannot reclaim intermediate blocks, so a JSON body that fit
`max_request_arena_bytes` could still fail. Dispatch now gives the response the
server allocator as a staging allocator and the final bytes are copied into the
arena once. Manually constructed responses keep the previous path.

Unit test: `json serialization stages growth outside a small arena` serializes
a 3000-byte value through a 4 KiB arena.

## Decoded body staging

`Ctx.decodedBody` decoded into the request arena, where decoder growth cannot
reclaim intermediate blocks. It now decodes in the server allocator and copies
the final bytes into the arena once when the result is owned; identity
encodings still borrow the original body.

Unit test: `decodedBody stages growth outside a small arena` decodes a
3000-byte gzip body through a 4 KiB arena.

## Buffered compression staging

Buffered compression grew its output in the request arena, so a body that fit
the arena could still fail to compress and fall back to identity. It now
compresses in the server allocator and copies the final bytes into the arena
once; genuine compression failures still fall back to identity.

Unit test: `compress middleware stages buffered growth outside a small arena`
compresses an incompressible 3000-byte body through a 4 KiB arena.

## Buffered HTTP/2 and HTTP/3 bodies

`readWholeBody` grew its accumulator inside the request arena. A request that
declares a non-zero `Content-Length` now allocates the body exactly in the
arena and fills it; an unknown-length body is staged in the server allocator
and copied into the arena once.

Package test: `package: HTTP/2 buffered body survives a small request arena`
posts a 3000-byte body against a 4 KiB arena.

## Failed route registration

`Router.addRaw` appended the route to the trie before registering it in
`all_routes`; an allocation failure on the latter left a freed route pointer
in the trie. The route is now registered in `all_routes` first and rolled back
if the trie append fails.

The same audit found that the capture-name array used a block-scoped
`errdefer`, so an allocation failure after that block leaked the names. The
release is now function-scoped.

Unit test: `failed registration leaves no route in the trie` injects every
allocation failure and asserts the trie, the ownership list, and the
allocation balance stay empty/clean.

## Verification

```sh
zig fmt --check src test bench examples build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
```

Results: 186/186 tests in Debug and ReleaseFast (130 unit, 56 package).
