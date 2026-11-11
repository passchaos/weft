# weft optimization backlog

Living list of code-structure, documentation, and build-hygiene work that is
not required for correctness but is worth scheduling. Items are intentionally
small enough to land one at a time with the existing test suite.

Baseline for the measurements below: `main` at `fd517d4` (working tree clean,
2026-11-10). Line numbers drift as the tree changes; treat them as pointers,
not contracts.

## Legend

- **P0** — high value, low risk, do first.
- **P1** — medium value; mechanical but touches several files.
- **P2** — optional or larger refactor; schedule after the P0/P1 work.
- Status: `todo`, `in progress`, `done`.

## Baseline snapshot (before this pass)

| Metric | Value |
| --- | ---: |
| `src/` files / lines | 41 / 18,937 |
| Source files above 900 lines | 10 |
| Unit tests (`src/`) | 170 |
| Package tests (`test/package_test.zig`) | 59 |
| `test/package_test.zig` lines | 6,486 |
| `docs/` files / lines | 7 / 2,216 |
| Largest doc | 1,424 lines, 85 `##` sections, 115 commits |
| Bench binaries in repo root | 3 × ~38 MB |
| `zig fmt --check` | passes |
| `TODO` / `FIXME` markers | none |

What is already healthy and should not regress:

- netz owns protocol codecs, framing, TLS, and QUIC; weft only maps requests
  and responses.
- Public application types stay concrete (`Ctx`, `Handler`, `Response`,
  `Router`); there is no `Service<Request>` or `Layer<S>` algebra.
- `Limits` is the single budget entry point and maps to every adapter.
- Middleware is one file per middleware; most modules carry inline tests.
- Doc-comment coverage is reasonable (`ctx.zig` 115, `router.zig` 79,
  `server.zig` 53 `///` lines).


## Completion snapshot (2026-11-10)

All items below are complete in the working tree. Verification:
`zig build check`; `zig build test` in Debug, ReleaseSafe, and ReleaseFast
(229/229 each); `zig build examples`; and a relative-link check over
`README.md`, `CHANGELOG.md`, `AGENTS.md`, and `docs/`.

| Metric | Baseline | Completion |
| --- | ---: | ---: |
| `src/` files / lines | 41 / 18,937 | 70 / 19,222 |
| Source files above 900 lines | 10 | 2 (`router.zig` 1,104; `static_files.zig` 919) |
| Unit tests (`src/`) | 170 | 170 |
| Package tests (`test/`) | 59 | 59 across 10 feature files + `support.zig` |
| `test/package_test.zig` lines | 6,486 | 12 (aggregator only) |
| `docs/` files / lines | 7 / 2,216 | 19 / 4,269 |
| Bench binaries in repo root | 3 × ~38 MB | 0 |
| `zig fmt --check` | passes | passes |

### Code outcomes

- **CODE-01**: `ctx.zig` is 749 lines; `body.zig` owns the reader stack and
  `handler.zig` owns `Handler`, `Locals`, `Param`, `Protocol`, `ClientInfo`,
  and the handler constructors.
- **CODE-02**: `router/trie.zig` owns the trie, captures, pattern validation,
  specificity, and method matching; router tests moved to `router_test.zig`.
  `router.zig` is 1,104 lines, about 10% above the original target because the
  generic `Router` registration and matching methods remain one cohesive unit.
- **CODE-03**: `compress.zig` is a 274-line facade; `compress/` owns
  negotiation, gzip, deflate, Brotli, zstd, and the continuous stream wrapper.
- **CODE-04**: `static_files.zig` is 919 lines; `static/path.zig`,
  `static/range.zig`, and `static/variants.zig` own the extracted helpers.
- **CODE-05**: `mcp.zig` is a 31-line facade; `mcp/types.zig` and
  `mcp/server.zig` own the protocol types and dispatch.
- **CODE-06**: `openapi.zig` is a 30-line facade; `openapi/types.zig`,
  `render.zig`, `ui.zig`, and `document.zig` own the rendering layers.
- **CODE-07**: shared `adapter/write.zig`, `body.zig`, `header_view.zig`, and
  `response.zig` replace the duplicated HTTP/1/2/3 helpers. HTTP/2 shrank from
  1,039 to 866 lines and HTTP/3 from 1,030 to 859.
- **CODE-08**: WebSocket handshake validation moved to `websocket.zig`;
  `server.zig` shrank from 943 to 899 lines.
- **CODE-09**: `multipart_stream.zig` shrank from 925 to 850 lines;
  `multipart/reader.zig` and `multipart/delimiter.zig` own the extracted
  pieces.
- **CODE-10**: `src/root.zig` is the only public barrel. Intermediate modules
  no longer re-export unrelated types; `ctx`, `router`, `server`,
  `http2_server`, and `http3_server` keep private aliases for internal use.
- **CODE-11**: `middleware/mod.zig` exports functions and types only; the
  inconsistent `_mod` submodule aliases are gone.
- **CODE-12**: `docs/architecture.md` and `docs/api.md` document the supported
  netz escape hatches; the README repeats the short version.
- **CODE-13**: semantic subdirectories were adopted for the split modules
  (`adapter/`, `router/`, `static/`, `mcp/`, `openapi/`, `multipart/`, and
  `middleware/compress/`). The remaining core request/response files stay at
  the top level: `root.zig` is the only public barrel, and moving them would
  add import churn without reducing coupling.

### Test outcomes

- **TEST-01**: `test/package_test.zig` is a 12-line aggregator. The 59 package
  tests live in `router_test.zig`, `http1_test.zig`, `http2_test.zig`,
  `http3_test.zig`, `tls_test.zig`, `static_test.zig`, `middleware_test.zig`,
  `websocket_test.zig`, `multipart_test.zig`, and `openapi_mcp_test.zig`, with
  shared fixtures in `test/support.zig`.

### Documentation outcomes

- **DOC-01**: README is 221 lines; detailed request/adapter/middleware/
  routing/static/OpenAPI/MCP/limits content moved to `docs/guide/`; the
  corrupted trailing line is gone.
- **DOC-02**: the 1,424-line HTTP/2 slice is now
  `docs/performance-journal.md`, with an append-only banner and an index link.
- **DOC-03**: `docs/README.md` indexes every living guide and historical
  snapshot.
- **DOC-04**: `docs/architecture.md` documents layers, module ownership,
  request lifecycle, arena rules, adapter differences, and the netz surface.
- **DOC-05**: `docs/performance.md` holds curated numbers; every table has
  date, snapshot, host, build, and command metadata.
- **DOC-06**: every dated validation file carries a historical-snapshot
  banner; `final-audit` no longer reads as a current claim.
- **DOC-07**: the README command list matches the `zig build` steps, including
  `test-package`, `check`, `examples`, `bench-h3`, `build-h3-bench`,
  `build-h2-hello-server`, and `bench-logging`.
- **DOC-08**: `docs/api.md` lists the public surface exported by
  `src/root.zig`.
- **DOC-09**: `CHANGELOG.md` records the 0.1.0 snapshot and the unreleased
  structural changes.
- **DOC-10**: `AGENTS.md` now has checkable rules for file size, the single
  public barrel, documentation lifecycle, performance metadata, and build
  artifacts.

### Build outcomes

- **BUILD-01**: `build.zig` is 289 lines and delegates repeated target wiring
  to `build/helpers.zig` (78 lines).
- **BUILD-02**: `zig build examples` builds all four examples, including
  `logging`, with one install artifact per target.
- **BUILD-03**: `zig build check` runs `zig fmt --check` and the full test
  suite; verified above.
- **BUILD-04**: the three stale `h3-bench-*` binaries are deleted and
  `.gitignore` covers `h3-bench-*` and `*.prof`.
- **BUILD-05**: the exact Zig pin is documented in `build.zig` and the
  compile error explains why `build.zig` and `build.zig.zon` must move
  together.


---

## Summary

| ID | Priority | Area | Item | Status |
| --- | --- | --- | --- | --- |
| WEFT-CODE-01 | P0 | Code | Split `src/ctx.zig` | done |
| WEFT-CODE-02 | P1 | Code | Split `src/router.zig` | done |
| WEFT-CODE-03 | P1 | Code | Split `src/middleware/compress.zig` | done |
| WEFT-CODE-04 | P1 | Code | Split `src/static_files.zig` | done |
| WEFT-CODE-05 | P1 | Code | Split `src/mcp.zig` | done |
| WEFT-CODE-06 | P1 | Code | Split `src/openapi.zig` | done |
| WEFT-CODE-07 | P0 | Code | Deduplicate HTTP/1/2/3 adapter glue | done |
| WEFT-CODE-08 | P2 | Code | Move WebSocket handshake helpers | done |
| WEFT-CODE-09 | P2 | Code | Split `src/multipart_stream.zig` | done |
| WEFT-CODE-10 | P2 | Code | Clean up re-export barrels | done |
| WEFT-CODE-11 | P2 | Code | Unify middleware module naming | done |
| WEFT-CODE-12 | P1 | Code | Decide/document the netz public surface | done |
| WEFT-CODE-13 | P2 | Code | Optional semantic `src/` subdirectories | done |
| WEFT-TEST-01 | P0 | Tests | Split `test/package_test.zig` | done |
| WEFT-DOC-01 | P0 | Docs | Fix README tail and split its responsibilities | done |
| WEFT-DOC-02 | P0 | Docs | Rename/split the performance journal | done |
| WEFT-DOC-03 | P0 | Docs | Add `docs/README.md` index | done |
| WEFT-DOC-04 | P1 | Docs | Add `docs/architecture.md` | done |
| WEFT-DOC-05 | P1 | Docs | Add `docs/performance.md` with metadata | done |
| WEFT-DOC-06 | P1 | Docs | Mark `final-audit` as historical | done |
| WEFT-DOC-07 | P1 | Docs | Sync README build commands with `build.zig` | done |
| WEFT-DOC-08 | P2 | Docs | Add an API reference or generated docs | done |
| WEFT-DOC-09 | P2 | Docs | Add a CHANGELOG | done |
| WEFT-DOC-10 | P1 | Docs | Add checkable guardrails to `AGENTS.md` | done |
| WEFT-BUILD-01 | P1 | Build | Factor repeated `build.zig` target blocks | done |
| WEFT-BUILD-02 | P1 | Build | Fix the `examples` step | done |
| WEFT-BUILD-03 | P2 | Build | Add a `check` step | done |
| WEFT-BUILD-04 | P0 | Build | Ignore and remove root bench binaries | done |
| WEFT-BUILD-05 | P2 | Build | Decide the Zig version pin policy | done |

---

## Code structure

### WEFT-CODE-01 — Split `src/ctx.zig` (P0)

**Evidence**

- 1,708 lines total; first test at line 1,054, so roughly 1,053 lines of
  implementation.
- Re-exports unrelated types at `src/ctx.zig:14-21`.
- Body-reader stack at `src/ctx.zig:23-186` (`ReplayReader`, `H2StreamReader`,
  `H3StreamReader`, `LimitedReader`, `DecodedReader`, `BodyReader`).
- Handler/locals stack at `src/ctx.zig:191-310` (`Param`, `Handler`, `Locals`,
  `max_params`, `max_locals`) and helpers at `src/ctx.zig:1010-1053`.

**Action**

- Extract `src/body.zig` for the reader types and their limits.
- Extract `src/handler.zig` for `Handler`, `Locals`, `Param`, `handler`,
  `handlerFor`, and `withContext`.
- Keep `Ctx` and request accessors in `src/ctx.zig`.
- Update `src/root.zig` to import moved symbols from their new owners.

**Acceptance**

- `src/ctx.zig` is under roughly 900 lines.
- Public names exported by `src/root.zig` do not change.
- `zig build test` remains 229/229.

### WEFT-CODE-02 — Split `src/router.zig` (P1)

**Evidence**

- 1,571 lines total; first test at line 1,204.
- Trie internals at `src/router.zig:134-200` and matching/validation helpers at
  `src/router.zig:1068-1203`.

**Action**

- Extract the trie node, segment iterator, captures, pattern validation, and
  specificity logic into `src/router/trie.zig`.
- Keep registration, groups, `Resolution`, and the public `Router` type in
  `src/router.zig`.
- Optionally move the OpenAPI projection into `src/router/openapi.zig`.

**Acceptance**

- `src/router.zig` is under roughly 1,000 lines.
- Precedence, conflict, and failed-registration tests are unchanged.

### WEFT-CODE-03 — Split `src/middleware/compress.zig` (P1)

**Evidence**

- 1,498 lines total, 616 lines before the first test; 17 inline tests.
- One file currently owns negotiation, buffered compression, streamed
  compression, and four coding implementations.

**Action**

- Create `src/middleware/compress/` with one module per coding (`gzip`,
  `deflate`, `brotli`, `zstd`) plus `negotiate.zig`.
- Keep `Compress` and `compress` as the public facade.

**Acceptance**

- The facade file is under roughly 400 lines.
- Streamed and buffered compression tests, including refused identity, pass.

### WEFT-CODE-04 — Split `src/static_files.zig` (P1)

**Evidence**

- 1,139 lines total; first test at line 897.
- Range parsing at `src/static_files.zig:813-896`.
- Path normalization at `src/static_files.zig:735-812`.
- Precompressed variant selection at `src/static_files.zig:568-703`.

**Action**

- Extract `src/static/range.zig`, `src/static/path.zig`, and
  `src/static/variants.zig`.
- Keep the `StaticFiles` handler and streaming glue in `src/static_files.zig`.

**Acceptance**

- `StaticFiles` public API is unchanged.
- Static-file package tests and range/path/variant unit tests pass.

### WEFT-CODE-05 — Split `src/mcp.zig` (P1)

**Evidence**

- 1,111 lines total; first test at line 925.
- Public protocol types at `src/mcp.zig:21-190`, server implementation at
  `src/mcp.zig:191-769`, helpers at `src/mcp.zig:770-924`.

**Action**

- Extract `src/mcp/types.zig` (tools, resources, prompts, options),
  `src/mcp/tool_context.zig` (argument and result builders), and
  `src/mcp/server.zig` (JSON-RPC dispatch).
- Keep `src/mcp.zig` as a thin facade.

**Acceptance**

- MCP package tests pass.
- `weft.mcp.Server`, `ToolContext`, and related public names are unchanged.

### WEFT-CODE-06 — Split `src/openapi.zig` (P1)

**Evidence**

- 990 lines total; first test at line 792.
- Schema/operation types at `src/openapi.zig:21-206`, document builder at
  `src/openapi.zig:207-269`, JSON renderers at `src/openapi.zig:270-791`, and
  the UI builder at `src/openapi.zig:757-791`.

**Action**

- Extract `src/openapi/types.zig`, `src/openapi/render.zig`, and
  `src/openapi/ui.zig`.
- Keep `Document` and its handlers as the public surface.

**Acceptance**

- OpenAPI unit tests pass.
- Rendered document shape is unchanged.

### WEFT-CODE-07 — Deduplicate HTTP/1/2/3 adapter glue (P0)

**Evidence**

- `writeWithBudget` exists three times: `src/server.zig:104`,
  `src/http2_server.zig:99`, `src/http3_server.zig:809`.
- `src/http2_server.zig:836-1038` and `src/http3_server.zig:820-1030` are
  near-verbatim copies of:
  `readWholeBody`, `convert*Trailers`, `convert*HeadersInto`,
  `convert*Headers`, `trailerFields`, `headerFields`, `lowerHeaderName`,
  `forbiddenResponseHeader`, `isPseudoHeader`, `findHeader`, and
  `internalErrorResponse`.
- `internalErrorResponse` also appears in `src/server.zig:880`.

**Action**

- Add `src/adapter/write.zig`, `src/adapter/body.zig`, and
  `src/adapter/header_view.zig`.
- Parameterize the header helpers over the HPACK/QPACK field type with
  `comptime`; keep protocol-specific stream types at the call sites.
- Keep one forbidden-response-header list and one host-synthesis rule.

**Acceptance**

- Roughly 200 lines removed from the two HTTP/2 and HTTP/3 adapters.
- No duplicated forbidden-header list remains.
- All adapter and package tests pass.

### WEFT-CODE-08 — Move WebSocket handshake helpers (P2)

**Evidence**

- `validWebSocketUpgrade` at `src/server.zig:838` and `offeredSubprotocol` at
  `src/server.zig:866`.
- `src/websocket.zig` is only 89 lines and already owns the session types.

**Action**

- Move both helpers into `src/websocket.zig`; keep only the call site in the
  HTTP/1 adapter.

**Acceptance**

- WebSocket package tests pass; `src/server.zig` shrinks.

### WEFT-CODE-09 — Split `src/multipart_stream.zig` (P2)

**Evidence**

- 925 lines total; first test at line 573; `DataReader` at lines 397-472.

**Action**

- Optionally extract the reader into `src/multipart/reader.zig`, keeping the
  stream state machine in `src/multipart_stream.zig`.

**Acceptance**

- Streaming multipart tests and parser-totality tests pass.

### WEFT-CODE-10 — Clean up re-export barrels (P2)

**Evidence**

- `src/ctx.zig:14-21` re-exports `Response`, `Header`, `Limits`, `SetCookie`,
  stream, SSE, and WebSocket types.
- `src/server.zig:13-18`, `src/http2_server.zig:14-19`, and
  `src/http3_server.zig:14-19` re-export the same adapter-facing set.
- `src/router.zig:6-9` re-exports `Ctx`, `Handler`, `Param`.

**Action**

- Make `src/root.zig` the only public barrel.
- Have each module export only the symbols it owns.
- Keep compatibility aliases temporarily if downstream code depends on them.

**Acceptance**

- `src/root.zig` exports the same public names.
- No module re-exports an unrelated module's types.

### WEFT-CODE-11 — Unify middleware module naming (P2)

**Evidence**

- `src/middleware/mod.zig:8-12` uses `compress_mod`, `metrics_mod`,
  `rate_limit_mod`, `etag_mod`, and `alt_svc_mod`, while other entries use
  plain names such as `cors` and `logging`.

**Action**

- Either drop the module aliases and export only functions/types, or use one
  consistent suffix for all module aliases.

**Acceptance**

- README middleware examples and package tests are unaffected.

### WEFT-CODE-12 — Decide and document the netz public surface (P1)

**Evidence**

- `src/root.zig:8` re-exports `netz` as `weft.netz`.
- Public signatures expose netz types such as `Header`, `TlsListenOptions`,
  `WriteStrategy`, and WebSocket `Frame` / `OwnedMessage`.

**Action**

- Decide whether these are supported escape hatches or implementation details.
- Document the decision in `docs/architecture.md` and the README.
- If they are internal, wrap the few types that leak and stop re-exporting
  `netz` wholesale.

**Acceptance**

- The documentation states which netz types applications may rely on.

### WEFT-CODE-13 — Optional semantic `src/` subdirectories (P2)

**Evidence**

- `src/` is flat with 41 Zig files; only `middleware/` is grouped.

**Action**

- Adopted semantic subdirectories for the split modules: `adapter/`,
  `router/`, `static/`, `mcp/`, `openapi/`, `multipart/`, and
  `middleware/compress/`.
- Kept the core request/response files at the top level because
  `src/root.zig` is the only public barrel and a further move would add import
  churn without reducing coupling.

**Acceptance**

- Import churn is contained in one PR and all tests pass.

---

## Tests

### WEFT-TEST-01 — Split `test/package_test.zig` (P0)

**Evidence**

- 6,486 lines, 59 tests, one `App` type, and shared helpers in one file.
- The location already matches `AGENTS.md`; only the size is the problem.

**Action**

- Add `test/support.zig` for `App`, common handlers, and connection helpers.
- Split tests by adapter/feature:
  `test/http1_test.zig`, `test/http2_test.zig`, `test/http3_test.zig`,
  `test/tls_test.zig`, `test/static_test.zig`, `test/middleware_test.zig`,
  `test/websocket_test.zig`, `test/multipart_test.zig`, and
  `test/openapi_mcp_test.zig`.
- Keep `test/package_test.zig` as an aggregator root that imports the files,
  so `build.zig` changes only if the root file is renamed.

**Acceptance**

- Test count stays 229 (170 unit + 59 package).
- `zig build test-package` passes.
- No test logic is rewritten; only moved and de-duplicated.

---

## Documentation

### WEFT-DOC-01 — Fix the README tail and split its responsibilities (P0)

**Evidence**

- `README.md` is 952 lines and mixes quick start, API guide, limits reference,
  benchmark report, status, and limitations.
- `README.md:773-901` is mostly performance narrative, not build instructions.
- `README.md:952` is a corrupted trailing fragment: `ve the raw file.`

**Action**

- Delete the corrupted trailing line.
- Move benchmark results and tuning conclusions to `docs/performance.md`.
- Keep README focused on: project shape, minimal example, request API summary,
  middleware overview, limits, lifecycle, build/test commands, status, and
  links to deeper docs.

**Acceptance**

- README is roughly 200–300 lines.
- No duplicated performance tables remain in README.
- All relative links resolve.

### WEFT-DOC-02 — Rename or split the performance journal (P0)

**Evidence**

- The former `docs/validation/2026-11-04-h2-suppressed-responses-and-bounded-trailers.md`
  (now `docs/performance-journal.md`) is 1,424 lines with 85 `##` sections.
- Its title covers two topics, but the content covers HTTP/1/2/3 performance,
  HPACK, arena allocation, ECN, scheduling, axum comparisons, and rejected
  experiments.
- The last 10 documentation commits all append to this one file.
- No other document links to it.

**Action**

- Preferred: rename it to `docs/performance-journal.md` (or
  `docs/validation/performance-journal-2026-11.md`) and add an
  “append-only, newest last” banner.
- Or split it into `docs/performance/http1.md`, `http2.md`, `http3.md`,
  `middleware-static-router.md`, and `rejected-experiments.md`.
- Treat dated validation files as immutable snapshots; put new living results
  in the new performance document.

**Acceptance**

- The title matches the content.
- The document is reachable from `docs/README.md`.
- Historical entries are preserved.

### WEFT-DOC-03 — Add `docs/README.md` index (P0)

**Evidence**

- README links only `../netz`, `../kron`, and `docs/logging.md`.
- All `docs/validation/` files are orphaned.

**Action**

- Add a docs index with sections for architecture, guides, performance,
  logging, validation snapshots, and the optimization backlog.
- Mark each entry as `living` or `historical`.

**Acceptance**

- Every file under `docs/` is reachable from the index.

### WEFT-DOC-04 — Add `docs/architecture.md` (P1)

**Content**

- Layer diagram: netz ↔ weft ↔ `std.Io`.
- Module map: which file owns routing, context, response building, adapters,
  parsing, and features.
- Request lifecycle: accept → dispatch → middleware → handler → response.
- Arena and ownership rules for request/response buffers and locals.
- Adapter differences: HTTP/1, HTTP/2, HTTP/3, TLS, Unix sockets, WebSocket.

**Acceptance**

- A new contributor can trace one request from socket to handler and back
  without reading the README end to end.

### WEFT-DOC-05 — Add `docs/performance.md` with metadata (P1)

**Evidence**

- Performance numbers live in README and in the validation journal.
- Most tables lack date, commit, host load, and exact command.

**Action**

- Create `docs/performance.md` with a standard header per table:
  date, commit, host load, command, build mode.
- Move the curated numbers from README there and link the raw journal.

**Acceptance**

- Every performance table carries the metadata header.
- README no longer contains long benchmark narratives.

### WEFT-DOC-06 — Mark `final-audit` as historical (P1)

**Evidence**

- `docs/validation/2026-11-04-final-audit.md:6` says 162/162 tests; the current
  suite is 229.
- Line references at `:13` point to `src/ctx.zig:226` and `src/ctx.zig:262`;
  `Handler` and `Ctx` are now at lines 253 and 311.
- The “Small cohesive files” row at `:17` is no longer true for the ten files
  above 900 lines.

**Action**

- Add a “Historical snapshot — 2026-11-04” banner and avoid present-tense
  claims, or re-run the audit and publish a new dated file.

**Acceptance**

- No current-state claim in the file is unqualified by a date.

### WEFT-DOC-07 — Sync README build commands with `build.zig` (P1)

**Evidence**

- README omits `test-package`, `examples`, `bench-h3`, `build-h3-bench`,
  `build-h2-hello-server`, and `bench-logging`.
- `bench-h3` is discussed in prose but missing from the command block.

**Action**

- Regenerate the command list from the `b.step(...)` names in `build.zig`.
- Document which steps are intentionally omitted and why.

**Acceptance**

- Every build step is either listed or explicitly excluded.

### WEFT-DOC-08 — Add an API reference or generated docs (P2)

**Evidence**

- README covers common usage but not every export from `src/root.zig`.
- Doc-comment coverage is good enough that generated docs would be useful.

**Action**

- Add `docs/api.md` or a `zig build doc` entry, and list the public surface:
  `Param`, `Protocol`, `ClientInfo`, `Prepared`, `Resolution`,
  `AllowedMethods`, `MimeType`, `default_mime_types`, `SetCookie`, `SameSite`,
  `handlerFor`, `withContext`, `RouteFailure`, and the module namespaces.

**Acceptance**

- Every `src/root.zig` export is documented or explicitly marked internal.

### WEFT-DOC-09 — Add a CHANGELOG (P2)

**Evidence**

- `build.zig.zon` is at `0.1.0` and there is no changelog.

**Action**

- Add `CHANGELOG.md` in Keep-a-Changelog style and record user-visible changes
  from the next release onward.

**Acceptance**

- The next release entry lists API, behavior, and performance changes.

### WEFT-DOC-10 — Add checkable guardrails to `AGENTS.md` (P1)

**Action**

- Add rules for:
  - file size (for example, split before a source file reaches ~1,000 lines);
  - one public barrel (`src/root.zig`);
  - living docs vs. dated historical snapshots;
  - performance-table metadata;
  - no build artifacts in the repository root.
- Keep the rules short enough to check in review.

**Acceptance**

- A reviewer can point to a specific rule when asking for a split or a doc
  move.

---

## Build and repository hygiene

### WEFT-BUILD-01 — Factor repeated `build.zig` target blocks (P1)

**Evidence**

- `build.zig` is 413 lines with ten benchmark targets, each repeating
  `addExecutable`, module imports, run artifact, and step wiring.

**Action**

- Add small helpers such as `addExample`, `addBench`, and `addServerBench`
  that take a name, source path, imports, and options.

**Acceptance**

- Step names and behavior are unchanged.
- `build.zig` drops to roughly 250 lines or fewer.

### WEFT-BUILD-02 — Fix the `examples` step (P1)

**Evidence**

- `build.zig:169-172` includes `hello`, `upload`, and `agent` but not
  `logging`.
- The step also calls `addInstallArtifact` again for targets that already use
  `installArtifact`.

**Action**

- Include the logging example and depend on the existing install steps once.

**Acceptance**

- `zig build examples` builds all four examples.

### WEFT-BUILD-03 — Add a `check` step (P2)

**Evidence**

- Validation docs run `zig fmt --check` manually; `build.zig` has no fmt or
  combined check step.

**Action**

- Add a `check` step that depends on formatting verification and `test`.

**Acceptance**

- `zig build check` verifies formatting and runs the test suite.

### WEFT-BUILD-04 — Ignore and remove root bench binaries (P0)

**Evidence**

- `h3-bench-manual`, `h3-bench-manual8`, and `h3-bench-prof` are about 38 MB
  each (~115 MB total).
- They are ignored only by the local `.git/info/exclude:8` rule
  `/h3-bench-*`; `.gitignore` does not cover them.

**Action**

- Delete the stale binaries.
- Add `h3-bench-*` (or a broader profiling-output pattern) to `.gitignore`.
- Write profiling output under `zig-out/` instead of the repository root.

**Acceptance**

- A fresh clone shows no untracked bench binaries.

### WEFT-BUILD-05 — Decide the Zig version pin policy (P2)

**Evidence**

- `build.zig:8` requires exactly `0.16.0`; `build.zig.zon` declares
  `minimum_zig_version = "0.16.0"`.

**Action**

- Decide whether the exact pin is intentional (std API churn) or whether a
  `0.16.x` range is acceptable.
- Document the rationale next to the check.

**Acceptance**

- The policy is explicit and the error message explains it.

---

## Suggested PR sequence

1. **PR1 — docs quick fixes (low risk)**
   WEFT-DOC-01 (tail), WEFT-DOC-03, WEFT-DOC-06, WEFT-DOC-07.
2. **PR2 — performance documentation**
   WEFT-DOC-02, WEFT-DOC-05.
3. **PR3 — build and repository hygiene**
   WEFT-BUILD-01, WEFT-BUILD-02, WEFT-BUILD-03, WEFT-BUILD-04.
4. **PR4 — test split**
   WEFT-TEST-01.
5. **PR5 — adapter deduplication**
   WEFT-CODE-07, WEFT-CODE-08.
6. **PR6 — large-file splits**
   WEFT-CODE-01 through WEFT-CODE-06, one file per commit.
7. **PR7 — guardrails and optional cleanups**
   WEFT-DOC-10, WEFT-CODE-10 through WEFT-CODE-13.

Each PR should run:

```sh
zig fmt --check src test bench examples build.zig
zig build test --summary all
```

Performance-sensitive changes should also run the relevant benchmark with
`-Doptimize=ReleaseFast` and record date, commit, host load, and command.

## Non-goals

- Do not introduce a generic `Service<Request>` or a deep `Layer<S>` algebra.
- Do not move protocol codecs, HTTP framing, TLS, or QUIC state machines into
  weft.
- Do not leak zio or operating-system types into public APIs; keep the runtime
  seam at `std.Io`.
- Do not replace bounded buffers or queues with unbounded collections.
- Do not perform a big-bang `src/` directory move before the file splits and
  the single-barrel cleanup.

---

## P0/P1 follow-up (2026-11-11)

The follow-up pass targets deployment and protocol capabilities beyond the
initial structure backlog.

| ID | Priority | Item | Status |
| --- | --- | --- | --- |
| WEFT-P0-01 | P0 | Unified TCP TLS ALPN listener (`h2` + `http/1.1`) | done |
| WEFT-P0-02 | P0 | HTTP/1.1 `Upgrade: h2c` | done |
| WEFT-P0-03 | P0 | External interoperability matrix and CI | done |
| WEFT-P1-01 | P1 | WebSocket over HTTP/2 and HTTP/3 (RFC 8441/9220) | done |
| WEFT-P1-02 | P1 | `103 Early Hints` API | done (HTTP/1.1, HTTP/2, buffered HTTP/3) |
| WEFT-P1-03 | P1 | Streaming response ETag | done (opt-in bounded) |
| WEFT-P1-04 | P1 | MCP sessions and server-initiated SSE | done |

### Progress notes

- **WEFT-P0-01**: `Http2Server.Options.alpn_http1` uses the new
  `netz.tls.alpn_server.Server` to negotiate `h2` and `http/1.1` on one TLS
  port. HTTP/2 uses `adoptNegotiatedTlsServer`; HTTP/1.1 uses a buffered
  fallback loop with streaming responses, but not WebSocket upgrades or
  incremental request bodies. A package test drives both protocols through the
  same port.
- **WEFT-P0-02**: `Http2Server.Options.h2c_upgrade` accepts HTTP/1.1
  `Upgrade: h2c` via `netz.http2.runtime.Server.acceptUpgradeWithTimeout`,
  dispatches stream 1 as a buffered response, and continues with the normal
  HTTP/2 concurrent engine. A package test drives the upgrade with netz's h2c
  client.
- **WEFT-P0-03**: `test/interop/run.sh` passes `curl` HTTP/1.1, `curl
  --http2-prior-knowledge`, and `nghttp` h2c. `h2spec` and HTTP/3 clients are
  reported as `SKIP` when not installed. `.github/workflows/ci.yml` runs
  `zig build check`, `zig build examples`, and the interop script.
- **WEFT-P1-02**: `Ctx.sendEarlyHints` writes interim heads on HTTP/1.1,
  HTTP/2, and buffered HTTP/3 responses. The HTTP/3 concurrent engine now
  forwards informational responses through the handshake session's
  `sendResponseWithInformational` path. Streamed HTTP/3 responses fail closed
  because the stream head has already been committed.
- **WEFT-P1-03**: `Etag.max_stream_bytes` buffers a streamed response up to the
  configured bound when the producer declares a known length, computes the
  content-derived tag, and then serves the buffered body. Unknown-length
  streams remain streaming and keep no ETag.
- **WEFT-P1-04**: `mcp.Options.sessions` enables `Mcp-Session-Id`, bounded
  per-session queues, `GET` SSE streams, `DELETE` termination, and
  `Server.notify`. Package tests cover initialize, session validation,
  notifications, SSE delivery, and deletion.
- **WEFT-P1-01**: WebSocket works over HTTP/1.1, HTTP/2, and HTTP/3.
  HTTP/2 uses RFC 8441: `Limits.http2_enable_connect_protocol` advertises the
  setting, the adapter detects `:protocol = websocket`, sends the 200 response,
  and runs the `netz.websocket.stream_connection` transport over the
  concurrent stream. HTTP/3 uses RFC 9220: `Http3Server` advertises
  `enable_connect_protocol`, the concurrent engine surfaces extended CONNECT
  heads, and the same stream transport runs over the QUIC request stream.
  `HandshakeServer.acceptBefore` now publishes the server SETTINGS before the
  request loop so event-driven clients do not deadlock waiting for peer
  capabilities. Extended CONNECT requests skip request-body aggregation
  because their stream stays open for WebSocket frames. Package tests echo a
  message with `netz.websocket.runtime.H2Client` and
  `netz.websocket.runtime.h3.Client`.

---

## Authentication and realtime adapters (2026-11-11)

This pass adds the application-security and realtime protocol surfaces that
were previously left to user code.

| ID | Priority | Item | Status |
| --- | --- | --- | --- |
| WEFT-P1-05 | P1 | Bounded session store and middleware | done |
| WEFT-P1-06 | P1 | CSRF middleware with Origin allow lists | done |
| WEFT-P1-07 | P1 | JWT HS256/EdDSA helpers and Bearer middleware | done |
| WEFT-P1-08 | P1 | WebTransport server adapter (datagrams and streams) | done |
| WEFT-P1-09 | P1 | Unary gRPC server adapter | done |

### Progress notes

- **WEFT-P1-05**: `weft.session.Store` keeps a bounded, process-local map with
  idle and absolute deadlines, LRU-style eviction, value-size limits, id
  rotation, and destruction. `Middleware` copies values into the request arena
  and writes them back after the handler chain, so no shared pointer escapes.
- **WEFT-P1-06**: `weft.csrf.Middleware` stores a synchronizer token in the
  session, exposes it through `weft.csrf.from(ctx)`, sets a non-HttpOnly
  double-submit cookie on safe methods, and requires `x-csrf-token` plus an
  optional exact `Origin` match on unsafe methods.
- **WEFT-P1-07**: `weft.jwt` signs and verifies compact JWS with HS256 and
  Ed25519, validates `exp`/`nbf`/`iss`/`aud`, rejects algorithm mismatches, and
  exposes `weft.middleware.Bearer` for RFC 6750 credentials.
- **WEFT-P1-08**: `weft.WebTransportServer(H)` wraps netz's QUIC/TLS
  WebTransport handshake runtime, dispatches exact CONNECT paths, and exposes
  datagrams, whole-stream and incremental reads, stream writes, close, and
  drain through `WebTransportSession`. Buffers are bounded by
  `max_stream_bytes` and `max_datagram_bytes`.
- **WEFT-P1-09**: `weft.GrpcServer(H)` wraps netz's HTTP/2 gRPC runtime for
  unary calls over h2c or TLS/ALPN `h2`, maps handler outcomes to gRPC status,
  bounds messages, calls per connection, and idle time, and sends a graceful
  GOAWAY at the call limit. Package tests cover echo, reuse, unimplemented,
  handler failure, and trailers-only statuses.

---

## Production depth pass (2026-11-11)

| ID | Priority | Item | Status |
| --- | --- | --- | --- |
| WEFT-P1-10 | P1 | TLS identity hot reload | done (SNI/ACME documented as external) |
| WEFT-P1-11 | P1 | Shared session storage seam and file store | done |
| WEFT-P1-12 | P1 | CSRF form-field tokens | done |
| WEFT-P1-13 | P1 | JWT RS256/ES256 and JWKS/OIDC verification | done |
| WEFT-P1-14 | P1 | Streaming gRPC and gRPC-Web | done |
| WEFT-P1-15 | P1 | WebTransport session timeout | done |
| WEFT-P1-16 | P1 | Response cache, signed cookies, CSP nonce, router composition | done |

### Progress notes

- **WEFT-P1-10**: netz HTTP/1 and HTTP/2 `TlsListenOptions` accept a
  `ServerIdentityProvider`; `weft.tls.ReloadableIdentity` owns generations,
  borrows one per handshake, and swaps certificates atomically. SNI
  multi-certificate selection and ACME issuance remain external concerns.
- **WEFT-P1-11**: `Store.Backend` is the shared-storage seam;
  `session.FileStore` implements it with atomic per-session files for
  shared-filesystem deployments. Redis/SQL backends implement the same
  callbacks.
- **WEFT-P1-12**: CSRF accepts the token from the configured header or from
  URL-encoded/multipart form fields.
- **WEFT-P1-13**: JWT verification covers RS256 (RSA-2048/e=65537), ES256,
  HS256, and Ed25519. `jwt.KeySet` parses JWKS documents, selects by `kid`, and
  verifies OIDC ID tokens with issuer/audience checks.
- **WEFT-P1-14**: `GrpcStreamingServer` accepts duplex streams, collects
  request messages, and writes multi-message responses. `GrpcServer` gains a
  `grpc_web` mode with optional CORS.
- **WEFT-P1-15**: `WebTransportServer.Options.session_timeout` caps every
  session method that lacks an explicit deadline.
- **WEFT-P1-16**: `middleware.Cache` is a bounded GET cache; `cookie_signer`
  provides HMAC-signed values; `SecurityHeaders` renders CSP nonces; the router
  gains `nest`, `merge`, named routes, and `urlFor`.
