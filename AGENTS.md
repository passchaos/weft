# weft development constraints

- `weft` is the application layer on top of `netz`; it must not duplicate protocol codecs, HTTP framing, TLS, or QUIC state machines.
- Public application APIs use a concrete `Ctx`, `Handler`, `Response`, and `Router`. Do not introduce a generic `Service<Request>` or a deep `Layer<S>` algebra.
- Keep the runtime seam at `std.Io`. Do not leak zio or operating-system types into public APIs.
- All request/response buffers, middleware queues, and connection counts must be bounded by `Limits`.
- `Ctx.next()` may be called at most once per handler invocation; short-circuiting is explicit.
- Keep files small and cohesive: router matching, response building, context/locals, server adapter, and each middleware in its own file.
- Split a source file before it reaches about 1,000 lines. New files above that size need a documented reason.
- `src/root.zig` is the only public barrel. Other modules export the symbols they own; do not re-export unrelated modules' types.
- Tests live next to the module they verify. Package-level integration tests belong in `test/`, split by adapter or feature rather than kept in one large file.
- Documentation separates living guides from dated snapshots. Dated files under `docs/validation/` are immutable historical records; update `docs/README.md` when adding a living document.
- Every performance table records date, commit, host, load, command, and build mode. Curated results live in `docs/performance.md`; raw measurements and rejected experiments go in `docs/performance-journal.md`.
- Do not keep build artifacts in the repository root. Write bench and profiling output under `zig-out/`, and keep `.gitignore` in sync.
- Every new `zig build` step must be listed in the README build/test section or explicitly documented as internal.
- Assume Zig 0.16.x semantics and prefer current standard-library APIs.
