# Static files

`weft.StaticFiles` serves files below a directory with validators, ranges, and
precompressed sidecars.

[Back to the documentation index](../README.md)

## Static files

`weft.StaticFiles` is a route handler that streams files below a directory. It
supports `ETag`/`Last-Modified` validators, RFC 9110 preconditions
(`If-Match`, `If-None-Match`, `If-Modified-Since`, `If-Unmodified-Since`),
`If-Range` with either an ETag or an HTTP-date, single and multipart `Range`
requests (`206`/`416`), `HEAD`, index files, MIME detection, dotfile rejection,
and traversal-safe path normalization.

```zig
var files = weft.StaticFiles{
    .dir = try std.Io.Dir.cwd().openDir(io, "public", .{}),
    .max_file_bytes = 8 * 1024 * 1024,
};

try router.addRaw(.GET, "/assets/*", files.handler(), .{});
```

`follow_symlinks` defaults to `false`; the handler checks the path with
`statFile(.follow_symlinks = false)` and rejects non-regular entries. Files
larger than `max_file_bytes` or `Limits.max_response_bytes` return `413`.
Directory requests without a trailing slash return `301` to the slash form,
preserving the query string, so relative links in the index document resolve
correctly; set `.redirect_directories = false` to serve the index in place.
Set `.download = true` to emit `Content-Disposition: attachment` with the
served basename; non-ASCII names also carry an RFC 5987 `filename*` value.

With `precompressed` enabled (the default), sibling `.br`, `.zst`, and `.gz`
sidecars are served according to `Accept-Encoding` (`br` preferred, then
`zstd`, then `gzip`, honouring `q` weights and `*`). The response keeps the
original `Content-Type`, adds `Content-Encoding` and `Vary: Accept-Encoding`,
and reports the sidecar's `Content-Length`/`ETag`. Sidecars older than the
source file are ignored by default; set `.check_sidecar_freshness = false` to
serve them anyway. Encoded representations are not range-addressable: a
request carrying `Range` always receives the raw file with
`Accept-Ranges: bytes`. Set `.precompressed = false` to disable sidecars.

