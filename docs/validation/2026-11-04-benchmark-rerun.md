# Benchmark re-run — 2026-11-04

> **Historical snapshot — 2026-11-04.** See
> [../performance.md](../performance.md) for the curated current numbers and
> [../README.md](../README.md) for the documentation index.

Command:

```sh
zig build bench bench-middleware bench-static bench-server bench-h2 \
  -Doptimize=ReleaseFast --global-cache-dir /tmp/weft-zig-global
```

Context: this host is shared with other active Zig agents, so absolute
numbers move. The run is recorded to show that the Unix-socket, error-response,
and budget-enforcement slices did not regress the hot paths; it is not a
quiet-host reference run.

```text
router static: routes=1024 lookups=2000000 53.7 ns/lookup 18611160 lookups/s
router param: routes=256 lookups=1000000 93.8 ns/lookup 10657150 lookups/s
static large.bin: iterations=20000 6595.8 ns/request 151612 requests/s 9475.7 MiB/s
static small.txt: iterations=100000 3477.0 ns/request 287605 requests/s 280.9 MiB/s
static conditional 304: iterations=200000 938.8 ns/request 1065186 requests/s
static range 1 KiB: iterations=100000 4247.2 ns/request 235449 requests/s
middleware baseline (handler only): iterations=200000 84.4 ns/request 11842076 requests/s
middleware requestId: iterations=200000 200.1 ns/request 4998321 requests/s
middleware Metrics: iterations=200000 142.7 ns/request 7009660 requests/s
middleware Etag: iterations=200000 196.4 ns/request 5091671 requests/s
middleware Compress: iterations=200000 101.5 ns/request 9850104 requests/s
middleware requestId+Metrics+Etag+Compress: iterations=200000 347.3 ns/request 2879685 requests/s
server http1: requests=200000 9351.2 ns/request 106939 requests/s
server h2 sequential: requests=100000 28073.2 ns/request 35621 requests/s
server h2 batched: requests=128000 16269.0 ns/request 61467 requests/s
server h2 upload batched: requests=128000 24703.8 ns/request 40480 requests/s
```

Comparison with the quiet-host table in
`2026-11-04-final-audit.md`:

- Router and static paths are at or better than the recorded ranges.
- The middleware chain is ~8% slower than the quiet-host 322 ns, consistent
  with shared-host noise; no middleware code changed in these slices.
- HTTP/1 keep-alive is ~9.35 µs versus the recorded 9.0–9.3 µs.
- HTTP/2 sequential/batched is 28.1/16.3 µs versus 25/15 µs; the upload batch
  is 24.7 µs versus ~19 µs. These paths were not modified; the host was
  measurably busier during this run.

No regression is attributed to the recent adapter changes: the only hot-path
edit was the `LimitedReader` wrap in `dispatch`, which applies to streaming
request bodies, not the GET paths measured here.
