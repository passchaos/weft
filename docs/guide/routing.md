# Routing

Segment-trie matching, precedence, groups, automatic `OPTIONS`, and fallback
handlers.

[Back to the documentation index](../README.md)

## Router

- Routes are indexed by a segment trie, so lookup cost scales with path depth
  rather than the number of registered routes.
- At each segment, a static child wins over `:param`, which wins over the
  trailing `*` wildcard. Precedence is decided at the leftmost differing
  segment, independent of registration order.
- `:param` captures one segment; `*` captures the remaining path.
- HTTP/1 absolute-form targets (`http://host/path?q=1`) are routed by their
  path and query; `ctx.target()` still exposes the original wire target.
- `router.any(...)` matches every method.
- `HEAD` falls back to a `GET` route when no explicit `HEAD` route exists.
- A path that exists for other methods returns `405` with an `Allow` field.
- `OPTIONS` is answered automatically with `204` and `Allow` when no explicit
  `OPTIONS` route exists. `OPTIONS *` advertises methods supported across the
  router.
- `router.group(prefix, options)` shares a prefix and middleware; groups can
  nest.
- Invalid patterns, duplicate method/path pairs, and wildcard/`any` conflicts
  are rejected at registration time.
- `Options.not_found`, `Options.bad_request`, and
  `Options.method_not_allowed` replace the default fallback bodies. They can
  inspect `ctx.get(weft.RouteFailure)`; the default status and `Allow` fields
  are pre-set before they run.
- Path depth, captures per route, allowed methods, and middleware length are
  all bounded.

