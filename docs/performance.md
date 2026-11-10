# weft performance

Curated performance results for the application layer. Raw, append-only
measurements and rejected experiments live in
[performance-journal.md](performance-journal.md).

## Measurement metadata

Every table in this document records the same metadata:

- **Date**: when the run was recorded.
- **Snapshot**: the commit the numbers were collected from.
- **Host**: the reference development host; it is shared with other work, so
  absolute numbers move with load.
- **Build**: `ReleaseFast` unless stated otherwise.
- **Command**: the exact benchmark step.

Curated snapshot for this page: **2026-11-04 – 2026-11-10**, commit
**`fd517d4`**, reference Linux development host, `ReleaseFast`. Individual
numbers were recorded at different times within that window; the journal keeps
the original context for each run.

## Router lookup

- Date: 2026-11-04 – 2026-11-10
- Snapshot: `fd517d4`
- Host: reference Linux host
- Build: `ReleaseFast`
- Command: `zig build bench -Doptimize=ReleaseFast`

The benchmark registers 1,024 static routes and 256 parameter routes.

| Case | Latency | Throughput |
| --- | ---: | ---: |
| Static lookup | 52–56 ns | 18–19M lookups/s |
| Parameter lookup | ~91 ns | ~11M lookups/s |

The parameter number includes capture allocation from a fixed arena.
Capture-free routes skip the parameter allocation entirely.

## Static files

- Date: 2026-11-04 – 2026-11-10
- Snapshot: `fd517d4`
- Host: reference Linux host
- Build: `ReleaseFast`
- Command: `zig build bench-static -Doptimize=ReleaseFast`

The benchmark measures `StaticFiles` end to end in-process: normalization,
stat, validators, and streamed reads, with a fixed request arena. Socket work
is excluded.

| Case | Latency | Throughput |
| --- | ---: | ---: |
| 64 KiB file | 6.3–10.4 µs | 96k–159k requests/s |
| 1 KiB file | 3.2–5.4 µs | 186k–311k requests/s |
| Conditional `304` | 0.87–1.24 µs | 808k–1.15M requests/s |
| Range, 1 KiB | 3.4–5.9 µs | 170k–291k requests/s |

Host load moves the file-read numbers; the `304` validator path is stable
because it never opens the file.

## Middleware chain

- Date: 2026-11-04 – 2026-11-10
- Snapshot: `fd517d4`
- Host: reference Linux host
- Build: `ReleaseFast`
- Command: `zig build bench-middleware -Doptimize=ReleaseFast`

The benchmark uses a fixed arena and no I/O, isolating weft's overhead from
netz framing.

| Chain | Latency |
| --- | ---: |
| Handler only | 32–40 ns/request |
| `requestId` | 84–104 ns/request |
| `securityHeaders` | 224–242 ns/request |
| `Metrics` | 88–103 ns/request |
| `Etag` | 72–82 ns/request |
| `Compress` | 35–41 ns/request |
| `requestId` + `Metrics` + `Etag` + `Compress` | 198–210 ns/request |

`requestId` seeds a per-thread PRNG once and then generates ids without a
syscall. `Compress` adds `Vary: Accept-Encoding` only when a coding is
actually possible, and `securityHeaders` uses a single-lookup default-field
helper.

## Accept negotiation

- Date: 2026-11-04 – 2026-11-10
- Snapshot: `fd517d4`
- Host: reference Linux host
- Build: `ReleaseFast`
- Command: `zig build bench-accept -Doptimize=ReleaseFast`

`bench-accept` measures allocation-free `Accept` negotiation against a
browser-style header and three candidates. Parsing the header once and using
integer quality weights reports about **0.82 µs** per `preferred` + `accepts`
pair (down from ~1.58 µs).

## HTTP/1 server

- Date: 2026-11-04 – 2026-11-10
- Snapshot: `fd517d4`
- Host: reference Linux host
- Build: `ReleaseFast`
- Command: `zig build bench-server -Doptimize=ReleaseFast`

`bench-server` measures one keep-alive HTTP/1 client against a one-worker
server. The result includes netz HTTP/1 framing and runtime task wakeups, not
just application dispatch.

| Run | Latency | Throughput |
| --- | ---: | ---: |
| Typical shared-host run | 9–16 µs | 60k–111k requests/s |
| Latest quiet-host run | 9.0 µs | 111k requests/s |

Requests without a body are parsed and completed without the per-request
producer task.

## HTTP/1 framework comparison

- Date: 2026-11-04 – 2026-11-10
- Snapshot: `fd517d4`
- Host: reference Linux host
- Build: `ReleaseFast`
- Command: `zig build build-hello-server -Doptimize=ReleaseFast`

`build-hello-server` produces a minimal `GET /` server for framework
comparisons. It defaults to `min(cpu_count, 8)` executors; override with
`WEFT_EXECUTORS`. Zio executors are most efficient when each one owns several
connections, so a 32-connection comparison should use fewer executors than
connections.

| Server | Throughput | p90 | p99 | p999 |
| --- | ---: | ---: | ---: | ---: |
| weft, 8 executors, 32 keep-alive connections | 1.02M–1.14M req/s | 31–37 µs | 41–49 µs | 55–68 µs |
| axum 0.8.9, default 32 tokio workers | 840k–867k req/s | 49–51 µs | 64–68 µs | 113–168 µs |
| axum 0.8.9, 8 workers | 728k–775k req/s | 56–59 µs | 71–75 µs | 90–135 µs |
| weft, 32 executors, 32 connections | 830k–955k req/s | — | 77–99 µs | 173–241 µs |

Sizing zio to 32 executors for 32 connections still wins throughput, but leaves
every executor mostly parked and the extra wake-up latency shows in the tail.

`WEFT_IO=threaded` runs the same server on `std.Io.Threaded` instead of the
zio backend. Interleaved rounds measured 1.38M–1.40M requests/s (p90 35 µs,
p99 105–117 µs, p999 304–378 µs) versus zio's 1.00M–1.03M and p999 57–66 µs.
Threaded trades tail latency and thread count for throughput, so zio remains
the default.

## Runtime backend and scheduling

- Date: 2026-11-04 – 2026-11-10
- Snapshot: `fd517d4`
- Host: reference Linux host
- Build: `ReleaseFast`
- Command: `zig build ... -Dscheduling=<mode> -Dzio-backend=<backend>`

`zig build` forwards `-Dscheduling` to netz and zio (`single_executor`,
`pinned`, or `work_stealing`; the default stays `work_stealing`) and
`-Dzio-backend` selects the event loop (`poll`, `linux`, `epoll`, `kqueue`,
`io_uring`, or `iocp`).

On the reference Linux host the default (`linux`, which resolves to io_uring)
beats `epoll` for HTTP/1: eight executors measured 1.07M–1.12M requests/s with
p999 64–67 µs on io_uring versus 818k–918k requests/s with p999 111–306 µs on
epoll.

With `-Dscheduling=pinned` each connection task stays on one executor. In the
32-connection comparison this measured lower p99/p999 tail latency
(p99 84–127 µs, p999 211–668 µs) with throughput in the same range as
`work_stealing` (955k–1041k vs 832k–990k requests/s across noisy rounds).
HTTP/2 batched and upload are neutral to slightly better with pinned, while
HTTP/3 sequential is slower (43.5–46.5 → 45.4–52.7 µs), so the default stays
`work_stealing`; use `pinned` when HTTP/1 tail latency matters most.

For a single-connection HTTP/2 deployment using `inline_bodyless` handlers,
`single_executor` removes idle-executor work stealing and brings the 32-stream
batch from 14.4–14.8 µs to 11.2–12.2 µs; multi-connection servers keep the
default.

## HTTP/2

- Date: 2026-11-04 – 2026-11-10
- Snapshot: `fd517d4`
- Host: reference Linux host
- Build: `ReleaseFast`
- Command: `zig build bench-h2 -Doptimize=ReleaseFast`

`bench-h2` measures one cleartext h2c connection: 100k sequential requests,
128k batched GETs, and 128k batched 2 KiB uploads, all in batches of 32
concurrent streams.

| Case | Latency |
| --- | ---: |
| Sequential | 18.7–19.3 µs/request |
| Batched GET | 7.6–8.0 µs/request |
| Batched 2 KiB upload | 11.9–12.8 µs/request |

With the `inline_bodyless` handler path and the combined head+body owner
write, the adapter submits the response head and the buffered body as one
owner command, so a sequential request no longer pays two command round trips.
HTTP/1 keep-alive on the same host is about 16 µs (~61k requests/s); H2
batched GET throughput exceeds HTTP/1, while the sequential path still pays
HTTP/2 framing.

`-Dh2-batch=<n>` and `-Dh2-batch-iterations=<n>` override the shape.

## HTTP/3

- Date: 2026-11-04 – 2026-11-10
- Snapshot: `fd517d4`
- Host: reference Linux host
- Build: `ReleaseFast`
- Command: `zig build bench-h3 -Doptimize=ReleaseFast`

`bench-h3` uses a synthetic QUIC handshake (no TLS): 10k sequential requests,
32k batched GETs, and 32k batched 2 KiB uploads, all in batches of 32 streams.

| Case | Latency |
| --- | ---: |
| Sequential, default 1 ms poll | 30–31 µs/request |
| Batched GET | 28–29 µs/request |
| Batched 2 KiB upload | ~51 µs/request |
| Batched GET, `-Dh3-batch=8` | ~39 µs/request |
| Batched upload, `-Dh3-batch=8` | ~57 µs/request |

The combined head+body command, netz's single-packet buffered response
emission, and the inline bodyless path are all active in these numbers. A 5 ms
poll interval measured ~10.1 ms/req sequentially before these fixes, so the
shorter default and the netz wake changes are both important for H3 latency.

## Logging producer cost

The structured access-log producer cost through kron is documented separately
with its own measured table and design evaluation:
[docs/logging.md](logging.md).

## Known performance limits

- HTTP/2 batch throughput is close to axum in external single-connection
  comparisons: a fresh interleaved run measured about 12.0–12.9 µs for weft
  versus 11.2–11.9 µs for axum (earlier quiet-host rounds were level at
  10.5–11.3 µs vs 10.6–10.8 µs). Sequential requests are 1.3–1.4× faster
  (33.4–36.8 µs vs 46.1–49.3 µs in the fresh run; 24.7–29.0 µs vs
  32.4–38.3 µs earlier). Routes that opt into `inline_bodyless` run bodyless
  handlers on the connection owner; `single_executor` still leads the batched
  path at 8.5–8.9 µs for a single connection.
- HTTP/1 p99/p999 tail latency depends on the zio executor count. Eight
  executors for 32 keep-alive connections beat axum on every percentile;
  sizing executors close to the connection count leaves each executor mostly
  parked and adds wake-up latency to the tail even though throughput stays
  ahead. Closing that last gap needs zio-level wake and scheduling work.
- HTTP/3 sequential latency is higher than HTTP/2 (roughly 29 µs vs 26–30 µs
  per request on the reference host); QUIC framing and recovery dominate.

## Post-refactor smoke run

- Date: 2026-11-10
- Snapshot: working tree after the structure/documentation optimization pass
  (baseline `fd517d4`)
- Host: reference Linux host, shared load
- Build: `ReleaseFast`
- Commands: the standard `zig build bench-*` steps; HTTP/2 and HTTP/3 used
  `-Dh2-batch=4 -Dh2-batch-iterations=10` and
  `-Dh3-batch=4 -Dh3-batch-iterations=10 -Dh3-warmup=2` for a short smoke run,
  so their batch numbers are not comparable to the tables above.

| Case | Result |
| --- | ---: |
| Router static / parameter | 47.2 ns / 79.1 ns per lookup |
| Static 64 KiB / 1 KiB | 6.25 µs / 3.84 µs per request |
| Static conditional `304` | 0.96 µs per request |
| Static range 1 KiB | 3.49 µs per request |
| Middleware `requestId`+`Metrics`+`Etag`+`Compress` | 199.3 ns per request |
| `Accept` negotiation | 841.6 ns per negotiation |
| HTTP/1 keep-alive | 8.39 µs per request, 119k requests/s |
| HTTP/2 sequential / batch=4 GET | 18.46 µs / 9.91 µs per request |
| HTTP/2 batch=4 upload | 14.54 µs per request |
| HTTP/3 sequential / batch=4 GET | 26.47 µs / 23.40 µs per request |
| HTTP/3 batch=4 upload | 38.70 µs per request |

The results are in the same ranges as the curated tables above; no regression
is attributed to the module splits or the shared adapter helpers.
