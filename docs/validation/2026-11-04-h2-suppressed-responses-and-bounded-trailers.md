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

## Static-file request formatting

`StaticFiles.serve` formatted the `ETag`, `Content-Range`, and precompressed
sidecar path with `allocPrint` into the request arena on every request, and
looked up the `Range` field up to three times. The values are now formatted
into stack buffers (falling back to the arena only for sidecar paths longer
than 512 bytes), and the `Range` lookup is cached.

Static benchmark (ReleaseFast, shared host, interleaved A/B against the
previous commit; directional because the host is noisy): small file
3.2–3.8 µs vs 4.6 µs, conditional 304 0.99–1.17 µs vs 1.36 µs, 1 KiB range
3.6–4.5 µs vs 4.9 µs.

## Response header validation

`Response.setHeader` validated the field name and value and then called
`appendHeader`, which validated both again. Appending is now a private
validated step shared by `setHeader` and `appendHeader`, and the constant
`Content-Type` fields added by `text` and `json` skip validation entirely.

Middleware benchmark (ReleaseFast, interleaved A/B): bare handler 36.4–38.2 ns
vs 59.6 ns, and the four-middleware chain 233–237 ns vs 297 ns.

## Cookie serialization and access-log formatting

`Ctx.setCookie` serialized the value into the arena and then `addHeader`
copied it again. Cookies up to 512 bytes now serialize into a stack buffer;
larger values keep the arena fallback. The access logger formats the client
address into a stack buffer instead of `allocPrint`.

HTTP/1 keep-alive benchmark (shared host, single run): 8.57 µs/request
(~117k requests/s). Static benchmarks: 6.30 µs (64 KiB), 3.21 µs (1 KiB),
0.87 µs (conditional 304), 3.44 µs (1 KiB range).

## Basic-auth credential comparison

`BasicAuth` decoded the client credentials into the request arena and built
`username:password` with `allocPrint` on every request. Credentials up to 256
bytes now decode onto the stack, and the comparison walks the configured parts
without concatenating them. The challenge realm is formatted on the stack as
well, with the arena retained for oversized values.

Unit test: `basic auth compares long credentials without concatenating`.

## Rate-limit eviction

When the client table was full, `RateLimit` scanned every bucket to find the
least-recently-seen victim, so inserting a new client cost O(clients). Buckets
now form an intrusive least-recently-used list: an existing client moves to
the tail on access, and a full table evicts the head in O(1). The unused-slot
scan and the per-bucket `last_seen` timestamp are gone.

Unit test: `rate limit eviction follows most-recent use`.

## Streaming multipart window rejection

`Stream.init` registered `errdefer allocator.free(boundary)` and then freed the
boundary explicitly after building the delimiter strings. Any later error (an
undersized window or a failed buffer allocation) freed it a second time. The
boundary now uses a plain `defer`, so it is released exactly once on both
paths.

Unit test: `streaming multipart rejects a window that cannot hold the
delimiter`.

## Streaming multipart part ownership

`parseHeaderBlock` duplicated a header name and value inside an append
argument; a failure between the two copies leaked the name. It also published
`part_name`, `part_filename`, and `part_content_type` before the final
`toOwnedSlice`, so an allocation failure left dangling slices that `deinit`
freed again. Each pair now has block-scoped ownership, and the part fields are
published only after the last fallible operation.

Unit test: `streaming multipart releases part state on allocation failure`
injects every allocation failure across init and part parsing.

## JSON and decoded-body staging cleanup

`Response.json` skipped releasing its staging buffer when no staging allocator
was configured, so a serialization or size failure leaked it. It also leaked
the finished body when appending the `Content-Type` field failed. The writer is
now released unconditionally (a no-op after `toOwnedSlice`), and the body has
an error-path release.

`Ctx.decodedBody` returned `PayloadTooLarge` when the arena could not hold the
decoded bytes without releasing the server-allocator buffer returned by the
decoder. The failure path now releases it.

Unit tests:
- `json releases staging when serialization fails` injects every allocation
  failure.
- `decodedBody releases staging when the arena is too small`.

## Allocation-failure coverage

Added `checkAllAllocationFailures` tests for buffered multipart parsing, query
parsing, cookie serialization, and static download dispositions. Cookie
serialization now maps the allocating writer's `WriteFailed` to `OutOfMemory`,
matching the other helpers; the other three paths were already balanced.

Unit tests: `buffered multipart releases ownership on allocation failure`,
`query parsing releases ownership on allocation failure`,
`cookie serialization releases ownership on allocation failure`, and
`static download disposition releases ownership on allocation failure`.

The same coverage now includes streaming `readBody` staging, wildcard route
registration, and route-group registration:
`readBody releases staging when the arena is too small`,
`failed wildcard registration leaves no route in the trie`, and
`failed group registration releases ownership`.

## Rate-limit rejection formatting

`RateLimit` formatted the `Retry-After` value with `allocPrint` on every
rejected request, adding an allocation exactly when the limiter is shedding
load. The value is now formatted into a stack buffer.

## Cookie validation before writing

`cookie.write` validated `Path`, `Domain`, and `Expires` while emitting them,
so a rejected attribute could leave a partial value in the caller's writer.
All attributes are now validated before the first byte is written.

Unit test: `cookie write validates before emitting bytes`.

## Compression Vary placement

`Compress` added `Vary: Accept-Encoding` before running the handler, so every
response paid for the field even when the body was below `min_bytes` or had a
non-compressible type — cases where no Accept-Encoding value can change the
representation. The field is now added after the handler only when the
response is eligible for compression (or when the client refused identity and
the response becomes 406). Identity responses for eligible bodies still carry
`Vary`.

Middleware benchmark: Compress 55.4 → 34.8–36.1 ns, and the four-middleware
chain 234.4 → 198.1–202.9 ns.

Unit test: `compress middleware omits Vary for bodies that never compress`.

## Default response fields

Middleware that supplies a default field performed `responseHeader` followed
by `setHeader`, scanning the response header list twice and validating twice.
`Response.setHeaderIfAbsent` performs one lookup and one validation pass.
`SecurityHeaders`, `AltSvc`, `Server`, and the SSE defaults use it.

Middleware benchmark: `securityHeaders` 273.4 → 224.2–242.1 ns; the bare
handler baseline is unchanged.

Unit test: `setHeaderIfAbsent keeps an existing field`.

## Accept negotiation

`accept.preferred` re-parsed the whole `Accept` header for every candidate and
used `std.fmt.parseFloat` for each quality value. It now parses the header
once into a bounded range array, evaluates all candidates against it, and uses
an integer thousandths parser that accepts only the RFC 9110 qvalue grammar.
Headers with more than 16 valid ranges keep the per-candidate fallback.

`qualityFor` keeps its public `?f64` signature and converts from the integer
weight. The new `bench-accept` step reports 1576.8 → 818.2–827.3 ns per
`preferred`+`accepts` pair.

Unit test: `accept preferred matches the per-candidate scan above the range
cap`.

## Shared qvalue parsing

`Accept`, `Compress`, and `StaticFiles` each carried their own qvalue parser;
`Compress` still used `std.fmt.parseFloat`, so an `Accept-Encoding` field with
q weights paid a float parse per coding. `src/quality.zig` now provides the
single integer-thousandths parser used by all three. The grammar is the RFC
9110 qvalue form (`0`/`1`, optional dot, at most three digits).

Unit test: `quality parses RFC qvalues into thousandths`.

## Body-helper arena exhaustion

`bodyJson`, `bodyForm`, `multipart`, and `multipartStream` parsed into the
fixed request arena and surfaced arena exhaustion as `OutOfMemory`, which
dispatch mapped to `500`. Since the arena is a request budget, exhaustion now
maps to `PayloadTooLarge` (`413`), matching `readBody`. `decodedBody` does the
same when no server staging allocator is configured; with staging enabled,
`OutOfMemory` still means a genuine server allocation failure.

Unit tests: `bodyForm maps arena exhaustion to PayloadTooLarge`,
`bodyJson maps arena exhaustion to PayloadTooLarge`,
`multipart maps arena exhaustion to PayloadTooLarge`,
`multipartStream maps arena exhaustion to PayloadTooLarge`, and
`decodedBody maps arena exhaustion to PayloadTooLarge`.

## Server-sent event batching

`sse.write` emitted one transport write per field (and per data line), so a
typical event cost three or four chunked writes. Events up to 512 bytes are
now formatted into one stack buffer and written once; larger events keep the
per-field streaming path. `sse.comment` is batched the same way.

Unit tests: `sse formats fields and splits multiline data` asserts one write
for a complete event, and `sse streams events larger than the batch buffer`
covers the fallback.

## Combined response head and body

The HTTP/2 and HTTP/3 adapters submitted the response head and the buffered
body as two owner commands. Both engines expose `startResponseWithBody`, which
commits the head and the first DATA contribution in one owner turn; the HTTP/3
engine can also emit a complete sequential response in one QUIC packet. Weft
uses the combined command for buffered responses and keeps the two-step path
for streamed bodies and for the empty-body-with-trailers case.

The HTTP/3 fast path requires the endpoint control streams. Netz now falls
back to the regular head+body path when SETTINGS/QPACK prefixes are not ready
yet instead of failing the stream (`netz` 9c99f7e5); the weft HTTP/3 package
test covers a first response during the handshake.

Benchmarks (ReleaseFast, shared host, interleaved A/B):
- HTTP/2 sequential 25.1 → 22.3–23.9 µs.
- HTTP/3 sequential 60.1 → 45.3–52.6 µs; batched 50.3 → 39.2–42.2 µs;
  upload 72.7 → 65.2–65.8 µs.

## Comparison with axum

A minimal `GET /` server was built for weft (`bench/hello_server.zig`,
`zig build build-hello-server -Doptimize=ReleaseFast`) and for axum 0.8.9
(`axum::serve` with the multi-thread tokio runtime). A standalone Rust load
generator with 32 blocking keep-alive connections and one request in flight
per connection drove both on the same host, alternating runs.

ReleaseFast, 32 connections, 5–6 s rounds on the shared reference host:
- axum: 700k–763k requests/s, p90 56–82 µs.
- weft (32 zio executors, `max_connections = 32`): 729k–889k requests/s,
  p90 56–66 µs — roughly 4–22% higher throughput.

Isolated CPU accounting measured 14.2 µs CPU/request for weft versus 11.0 µs
for axum; weft's higher throughput comes from using more of the 32 cores.

The bodyless-request fast path in netz (`1a19d91b`) removes the per-request
producer task: `readRequestBodyWithBuffer` parses and completes a request with
no body (or `Content-Length: 0`) on the calling task. Requests with a body,
`Expect`, obs-fold, or more than 128 fields keep the producer path with the
buffered head untouched. On the same host this moved weft from ~565k to
~850k requests/s at 32 connections and cut CPU per request from 22.7 µs to
14.2 µs.

Caveats: the host is shared with other agents, so absolute numbers move
between runs; both servers use default framework settings except weft's
executor count and connection cap. The axum project and load generator are
one-off harnesses outside the repository.

## Verification

```sh
zig fmt --check src test bench examples build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build bench-accept -Doptimize=ReleaseFast
```

Results: 213/213 tests in Debug, ReleaseSafe, and ReleaseFast (157 unit,
56 package).
