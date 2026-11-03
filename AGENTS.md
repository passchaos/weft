# weft development constraints

- `weft` is the application layer on top of `netz`; it must not duplicate protocol codecs, HTTP framing, TLS, or QUIC state machines.
- Public application APIs use a concrete `Ctx`, `Handler`, `Response`, and `Router`. Do not introduce a generic `Service<Request>` or a deep `Layer<S>` algebra.
- Keep the runtime seam at `std.Io`. Do not leak zio or operating-system types into public APIs.
- All request/response buffers, middleware queues, and connection counts must be bounded by `Limits`.
- `Ctx.next()` may be called at most once per handler invocation; short-circuiting is explicit.
- Keep files small and cohesive: router matching, response building, context/locals, server adapter, and each middleware in its own file.
- Tests live next to the module they verify. Package-level integration tests belong in `test/`.
- Assume Zig 0.16.x semantics and prefer current standard-library APIs.
