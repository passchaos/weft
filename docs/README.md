# weft documentation

Start with the project [README](../README.md) for the shape and a runnable
example. This index separates living documents from dated historical
snapshots.

## Living documents

These are kept in sync with the current tree.

| Document | What it covers |
| --- | --- |
| [../README.md](../README.md) | Project shape, minimal example, build/test commands, status, limitations |
| [architecture.md](architecture.md) | Layers, module map, request lifecycle, arena ownership, adapter differences |
| [api.md](api.md) | Public API surface exported by `src/root.zig` |
| [performance.md](performance.md) | Curated benchmark results with measurement metadata |
| [logging.md](logging.md) | kron integration, measured producer cost, design assessment |
| [optimization-backlog.md](optimization-backlog.md) | Pending structure, documentation, and build work |
| [../CHANGELOG.md](../CHANGELOG.md) | User-visible changes |

## Guides

| Document | What it covers |
| --- | --- |
| [guide/request.md](guide/request.md) | `Ctx`, decoded inputs, body helpers, streaming responses and request bodies |
| [guide/adapters.md](guide/adapters.md) | TLS, Unix sockets, HTTP/2, HTTP/3, WebSockets |
| [guide/routing.md](guide/routing.md) | Segment trie, precedence, groups, automatic `OPTIONS`, fallbacks |
| [guide/middleware.md](guide/middleware.md) | Middleware contract, order, built-ins, access logging |
| [guide/static-files.md](guide/static-files.md) | Validators, ranges, index files, precompressed sidecars |
| [guide/auth.md](guide/auth.md) | Sessions, CSRF, JWT, and Bearer authentication |
| [guide/webtransport-grpc.md](guide/webtransport-grpc.md) | WebTransport sessions and unary gRPC adapters |
| [guide/openapi-mcp.md](guide/openapi-mcp.md) | OpenAPI 3.1 documents and the MCP Streamable HTTP server |
| [guide/limits-lifecycle.md](guide/limits-lifecycle.md) | `Limits`, connection bounds, cooperative shutdown |

## Performance

- [performance.md](performance.md) — curated numbers for the current tree.
- [performance-journal.md](performance-journal.md) — append-only engineering
  journal with raw measurements and rejected experiments.
- [logging.md](logging.md) — structured-logging producer cost.

## Historical snapshots

These files are dated records. They describe the tree at the date in their
title and are not updated to match later commits.

| Document | Date |
| --- | --- |
| [validation/2026-11-03-router-server-slice.md](validation/2026-11-03-router-server-slice.md) | 2026-11-03 |
| [validation/2026-11-04-adapter-request-budgets.md](validation/2026-11-04-adapter-request-budgets.md) | 2026-11-04 |
| [validation/2026-11-04-benchmark-rerun.md](validation/2026-11-04-benchmark-rerun.md) | 2026-11-04 |
| [validation/2026-11-04-final-audit.md](validation/2026-11-04-final-audit.md) | 2026-11-04 |
| [validation/2026-11-04-unix-sockets-and-error-drain.md](validation/2026-11-04-unix-sockets-and-error-drain.md) | 2026-11-04 |

The 2026-11-04 HTTP/2 slice grew into the living
[performance-journal.md](performance-journal.md); its historical scope note is
preserved at the top of that file.
