# Structured logging with kron

`weft` uses [kron](../kron) for structured request logging. This note records
the integration shape, the measured producer cost, and the evaluation of
kron's current design.

## Integration

- `weft.logging.AccessLog` is a normal middleware handler. It emits one typed
  kron event per request with `request_id`, `method`, `path`, `query`,
  `status`, `duration_ns`, `protocol`, `remote`, and `err`.
- `weft.logging.logf`/`logWarn`/`logErr`/`logInfo`/`logDebug` route weft's
  internal diagnostics through kron's process-wide owner when the application
  installs one with `kron.setGlobalLogging`, and fall back to `std.log`
  otherwise. netz's HTTP/1 serve-loop error observer uses the same global
  owner.
- The application owns the `kron.Logging` lifecycle; weft stores only the
  pointer and never destroys it.
- `zig build run-logging` starts the example; `zig build bench-logging` runs
  the producer benchmark.

## Measured producer cost

`bench/logging.zig` emits a fixed 9-field access event through a JSON output
whose sink is `std.Io.Writer.Discarding`, so the numbers exclude sink I/O.
On the reference host (load roughly 5–8) with ReleaseFast:

| Path | ns/event | events/s |
| --- | ---: | ---: |
| `Logging.scoped` facade, sync JSON | 441–448 | 2.23M–2.27M |
| direct `scopedOutput` runtime logger | 445 | 2.24M |
| `Logging.scoped` facade, async memory queue | 452–504 | 1.98M–2.21M |

The facade and the direct per-output runtime logger are within noise; the
thread-local frame bookkeeping and single-output fast path are already cheap.
At 1M requests/s, one access event per request costs roughly 0.45 of a core,
so access logging is a deliberate production choice: filter/sample at the
route level, use asynchronous mode, or keep the access log off for
latency-critical endpoints.

A profile of the sync run attributes about 21% of samples to
`ValueValidator`/`codec.measure`, 9% to `Runtime.submitSafeDestination`, 7% to
`Owner.beginOne`, 7% to `Journal.reserve`, 9% to `memcpy`, and the rest to
JSON rendering and escaping. The capture/measure walk is the largest
producer-side block.

## Design assessment

kron's design is appropriate for weft's use case:

- Typed capture is allocation-free on the producer path; borrowed slices stay
  valid only until `tryEmit` returns, and the owner copies before accepting.
- Admission (level, filter, sampling, predicates) runs before field capture,
  so filtered events skip most work.
- Each output is an independent bounded pipeline; the single-output fast path
  avoids fanout bookkeeping.
- Memory/Mmap queues, delivery modes, redaction, sampling, and the std.log
  bridge are per-route and explicitly bounded.
- Borrowed trees are re-validated at the reservation boundary. This is
  deliberate: clock and predicate callbacks run between capture and submit and
  may mutate a borrowed tree, so `Event.tree_validated` is not trusted for
  captured events.

## Optimization experiments

- **Trusted measure (rejected).** The profile suggested skipping the second
  validation walk when `tree_validated` is set. Implementing a size-only walk
  made the producer faster in isolation, but kron's existing tests
  (`clock mutation of a borrowed tree is validated again before reservation`,
  `admission measurement preserves pre-filter tree errors`) failed: a clock or
  predicate callback can mutate the borrowed tree after capture. Trusting the
  hint also let a caller-supplied duplicate tree bypass `DuplicateKey`. The
  experiment was reverted; the re-validation is a safety invariant, not
  accidental work. A safe version needs provenance that distinguishes a
  checked, immutable decoder tree from a captured borrowed tree.
- **Direct runtime logger (neutral).** `Logging.scopedOutput` bypasses the
  multi-output facade, but measured within noise of `Logging.scoped`, so weft
  keeps the simpler facade API.
- **Typed duration (kept).** `AccessLog` emits `duration_ns` with
  `kron.durationNs`, which uses the 9-byte duration wire value instead of the
  17-byte generic integer and preserves the numeric JSON rendering.

## Practical guidance

- Use `AccessLog` with `requestId` before it; the event carries the request id
  without an extra lookup.
- Prefer asynchronous mode with a bounded memory queue for production access
  logs; sync mode performs encoding and sink writes on the request thread.
- Use route filters, sampling, or a separate access-log route to bound cost.
- For JSON-heavy asynchronous routes, kron's opt-in `render_cache` can move
  rendering to the producer; it is a per-route option and remains disabled by
  default.
- Install the same owner with `kron.setGlobalLogging` to collect weft and netz
  diagnostics; without it, those diagnostics fall back to `std.log`.
