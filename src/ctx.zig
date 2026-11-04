const std = @import("std");
const netz = @import("netz");
const response_mod = @import("response.zig");
const limits_mod = @import("limits.zig");
const query_mod = @import("query.zig");
const cookie_mod = @import("cookie.zig");
const stream_mod = @import("stream.zig");
const accept_mod = @import("accept.zig");
const multipart_mod = @import("multipart.zig");
const multipart_stream_mod = @import("multipart_stream.zig");
const sse_mod = @import("sse.zig");
const websocket_mod = @import("websocket.zig");

pub const Response = response_mod.Response;
pub const Header = netz.http1.Header;
pub const Limits = limits_mod.Limits;
pub const QueryPair = query_mod.Pair;
pub const SetCookie = cookie_mod.SetCookie;
pub const StreamBody = stream_mod.Body;
pub const StreamWriter = stream_mod.Writer;
pub const SseEvent = sse_mod.Event;
/// One-chunk reader for adapters that already buffered the request body.
pub const ReplayReader = struct {
    body: []const u8,
    consumed: bool = false,

    pub fn next(self: *ReplayReader) !?[]const u8 {
        if (self.consumed) return null;
        self.consumed = true;
        return self.body;
    }
};

/// Pull reader over an HTTP/2 concurrent stream.
pub const H2StreamReader = struct {
    stream: *netz.http2.runtime.Connection.ConcurrentStream,
    buffer: [16 * 1024]u8 = undefined,

    pub fn next(self: *H2StreamReader) !?[]const u8 {
        while (true) {
            const count = (try self.stream.nextBody(
                &self.buffer,
                null,
            )) orelse return null;
            if (count != 0) return self.buffer[0..count];
        }
    }
};

pub const H3StreamReader = struct {
    stream: *netz.http3.runtime.HandshakeServerSession.ConcurrentStream,
    buffer: [16 * 1024]u8 = undefined,

    pub fn next(self: *H3StreamReader) !?[]const u8 {
        while (true) {
            const count = (try self.stream.nextBody(
                &self.buffer,
                null,
            )) orelse return null;
            if (count != 0) return self.buffer[0..count];
        }
    }
};

/// Per-route body budget wrapper. Returns `error.PayloadTooLarge` before
/// handing out a chunk that would exceed the route's limit.
pub const LimitedReader = struct {
    inner: BodyReader,
    remaining: usize,

    pub fn next(self: *LimitedReader) !?[]const u8 {
        const chunk = (try self.inner.next()) orelse return null;
        if (chunk.len > self.remaining) return error.PayloadTooLarge;
        self.remaining -= chunk.len;
        return chunk;
    }
};

/// Incremental request-body source. HTTP/1 uses netz's pull reader, HTTP/2
/// pulls from a duplex/concurrent stream, and HTTP/3 pulls from the concurrent
/// stream engine (or replays a buffered body on the legacy adapter).
pub const BodyReader = union(enum) {
    pull: *netz.http1.runtime.RequestBodyReader,
    duplex: *netz.http2.runtime.ServerDuplexStream,
    h2_stream: *H2StreamReader,
    h3_stream: *H3StreamReader,
    replay: *ReplayReader,
    limited: *LimitedReader,

    pub fn next(self: BodyReader) !?[]const u8 {
        return switch (self) {
            .pull => |reader| reader.next(),
            .duplex => |stream| stream.nextBody(),
            .h2_stream => |reader| reader.next(),
            .h3_stream => |reader| reader.next(),
            .replay => |reader| reader.next(),
            .limited => |reader| reader.next(),
        };
    }
};
pub const WebSocketSession = websocket_mod.Session;
pub const WebSocketUpgrade = websocket_mod.Upgrade;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// Transport/version metadata for the current request.
pub const Protocol = enum {
    http_1_0,
    http_1_1,
    http_2,
    http_3,
};

pub const ClientInfo = struct {
    /// Peer address when the adapter can expose one.
    address: ?std.Io.net.IpAddress = null,
    protocol: Protocol = .http_1_1,
    tls: bool = false,
    /// Verified client certificate chain for mutual TLS, leaf first. Empty
    /// when the listener does not request client certificates.
    peer_certificates: []const []const u8 = &.{},
};

/// Resolve the client address, optionally honoring the leftmost
/// `X-Forwarded-For` entry. The header is only consulted when the caller
/// explicitly trusts its proxy.
pub fn resolveClientAddress(
    headers: anytype,
    peer: ?std.Io.net.IpAddress,
    trust_forwarded_for: bool,
) ?std.Io.net.IpAddress {
    if (!trust_forwarded_for or peer == null) return peer;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for")) continue;
        var entries = std.mem.splitScalar(u8, header.value, ',');
        while (entries.next()) |raw| {
            var candidate = std.mem.trim(u8, raw, " \t");
            if (candidate.len >= 2 and candidate[0] == '"' and
                candidate[candidate.len - 1] == '"')
            {
                candidate = candidate[1 .. candidate.len - 1];
            }
            if (candidate.len == 0) continue;
            const parsed = std.Io.net.IpAddress.parse(candidate, 0) catch
                continue;
            return parsed;
        }
        return peer;
    }
    return peer;
}

/// Maximum path parameters captured for one route. The bound keeps the matcher
/// allocation-free until a route actually matches.
pub const max_params = 16;

/// The single handler contract used by routes and middleware.
///
/// A handler receives only `*Ctx`. Application state is available through
/// `ctx.app`; parameterized middleware can store its state in `context` and use
/// `withContext`.
pub const Handler = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, *Ctx) anyerror!void,

    pub fn call(self: Handler, ctx: *Ctx) anyerror!void {
        return self.call_fn(self.context, ctx);
    }
};

/// Request-scoped typed locals.
///
/// Keys are `@typeName(T)` strings, so only one value per type is stored.
/// Values are allocated in the request arena and are valid until the response
/// has been written.
pub const Locals = struct {
    map: std.StringHashMapUnmanaged(*anyopaque) = .empty,

    pub fn put(
        self: *Locals,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: *anyopaque,
    ) !void {
        try self.map.put(allocator, key, value);
    }

    pub fn get(self: *const Locals, key: []const u8) ?*anyopaque {
        return self.map.get(key);
    }
};

/// Per-request execution context.
///
/// The chain is explicit: `middleware` runs first, then `final_handler`.
/// Middleware calls `ctx.next()` to continue; not calling it short-circuits.
/// `next()` may be called at most once per handler invocation.
pub const Ctx = struct {
    app: *anyopaque,
    io: std.Io,
    arena: std.mem.Allocator,
    /// Server allocator that owns transport request metadata. Used to release
    /// a completed HTTP/1 streaming request after taking its trailers.
    request_allocator: ?std.mem.Allocator = null,
    limits: Limits,
    request: *const netz.http1.Request,
    /// Bounded incremental body reader for routes registered with
    /// `RouteOptions.streaming`. Null for buffered requests.
    body_reader: ?BodyReader = null,
    /// Body cached by `readBody` after a streaming read.
    cached_body: ?[]const u8 = null,
    /// Trailer view cached after a streaming read.
    cached_trailers: ?[]const Header = null,
    client_info: ClientInfo = .{},
    /// Absolute handler deadline when `Limits.request_timeout` is configured.
    request_deadline: ?std.Io.Clock.Timestamp = null,
    query: []const u8 = "",
    /// Decoded query pairs, bounded by `limits.max_query_params`.
    query_params: []const QueryPair = &.{},
    /// Decoded path captures. `Router` produces raw captures; the server
    /// decodes them before invoking handlers.
    params: []const Param = &.{},
    response: Response,
    locals: Locals = .{},
    middleware: []const Handler = &.{},
    final_handler: Handler,
    index: usize = 0,
    final_called: bool = false,
    next_allowed: bool = false,

    pub fn run(self: *Ctx) anyerror!void {
        self.index = 0;
        self.final_called = false;
        self.next_allowed = true;
        try self.next();
    }

    pub fn next(self: *Ctx) anyerror!void {
        if (!self.next_allowed) return error.NextNotAllowed;
        self.next_allowed = false;

        if (self.index < self.middleware.len) {
            const middleware_handler = self.middleware[self.index];
            self.index += 1;
            return self.callHandler(middleware_handler);
        }

        if (!self.final_called) {
            self.final_called = true;
            return self.callHandler(self.final_handler);
        }
    }

    fn callHandler(self: *Ctx, entry: Handler) anyerror!void {
        const previous = self.next_allowed;
        self.next_allowed = true;
        defer self.next_allowed = previous;
        return entry.call(self);
    }

    pub fn method(self: *const Ctx) netz.http1.Method {
        return self.request.method;
    }

    pub fn protocol(self: *const Ctx) Protocol {
        return self.client_info.protocol;
    }

    pub fn clientAddress(self: *const Ctx) ?std.Io.net.IpAddress {
        return self.client_info.address;
    }

    pub fn isTls(self: *const Ctx) bool {
        return self.client_info.tls;
    }

    /// Verified client certificate chain for mutual TLS, leaf first. Empty
    /// when the listener did not request a client certificate.
    pub fn peerCertificates(self: *const Ctx) []const []const u8 {
        return self.client_info.peer_certificates;
    }

    pub fn deadline(self: *const Ctx) ?std.Io.Clock.Timestamp {
        return self.request_deadline;
    }

    pub fn remaining(self: *const Ctx) ?std.Io.Duration {
        const absolute = self.request_deadline orelse return null;
        return absolute.durationFromNow(self.io).raw;
    }

    pub fn expired(self: *const Ctx) bool {
        const left = self.remaining() orelse return false;
        return left.nanoseconds <= 0;
    }

    pub fn target(self: *const Ctx) []const u8 {
        return self.request.target;
    }

    pub fn header(self: *const Ctx, name: []const u8) ?[]const u8 {
        return self.request.header(name);
    }

    pub fn headers(self: *const Ctx) []const Header {
        return self.request.headers;
    }

    pub const HeaderIterator = struct {
        headers: []const Header,
        name: []const u8,
        index: usize = 0,

        pub fn next(self: *HeaderIterator) ?[]const u8 {
            while (self.index < self.headers.len) : (self.index += 1) {
                const field = self.headers[self.index];
                if (std.ascii.eqlIgnoreCase(field.name, self.name)) {
                    self.index += 1;
                    return field.value;
                }
            }
            return null;
        }
    };

    pub fn headerValues(self: *const Ctx, name: []const u8) HeaderIterator {
        return .{ .headers = self.request.headers, .name = name };
    }

    pub fn body(self: *const Ctx) []const u8 {
        return self.request.body;
    }

    /// Incremental request-body reader for streaming routes. Null on buffered
    /// routes; use `readBody` when the whole body is needed.
    pub fn bodyReader(self: *const Ctx) ?BodyReader {
        return self.body_reader;
    }

    /// Read the complete request body. Streaming routes drain the bounded
    /// reader into the request arena; buffered routes return the parsed body.
    /// Repeated calls return the cached result.
    pub fn readBody(self: *Ctx) ![]const u8 {
        if (self.cached_body) |cached| return cached;

        const reader = self.body_reader orelse {
            self.cached_body = self.request.body;
            return self.request.body;
        };

        var output = std.ArrayListUnmanaged(u8).empty;
        var total: usize = 0;
        while (try reader.next()) |chunk| {
            const next_total = std.math.add(usize, total, chunk.len) catch
                return error.PayloadTooLarge;
            if (next_total > self.limits.max_body_bytes or
                next_total > self.limits.max_request_arena_bytes)
            {
                return error.PayloadTooLarge;
            }
            try output.appendSlice(self.arena, chunk);
            total = next_total;
        }
        self.cached_body = output.items;
        return output.items;
    }

    /// True when the request's `Accept` header allows `media_type`
    /// (`type/subtype`). A missing header accepts anything; the most specific
    /// matching range wins, so an explicit `q=0` rejects.
    pub fn accepts(self: *const Ctx, media_type: []const u8) bool {
        return accept_mod.accepts(self.header("accept"), media_type);
    }

    /// Choose the candidate with the highest accepted quality, keeping the
    /// earliest candidate on ties. Returns null when none is acceptable.
    pub fn preferredType(
        self: *const Ctx,
        candidates: []const []const u8,
    ) ?[]const u8 {
        return accept_mod.preferred(self.header("accept"), candidates);
    }

    /// Request trailer fields. Streaming adapters expose trailers after the
    /// body has been consumed; buffered adapters expose them immediately.
    pub fn trailers(self: *Ctx) []const Header {
        if (self.cached_trailers) |cached| return cached;
        if (self.body_reader) |reader| {
            switch (reader) {
                .pull => |pull| {
                    if (pull.requestReady()) {
                        const owned = pull.takeRequest() catch null;
                        if (owned) |value| {
                            var request_meta = value;
                            defer if (self.request_allocator) |allocator| {
                                request_meta.deinit(allocator);
                            };
                            if (request_meta.trailers.len != 0) {
                                self.cached_trailers = self.copyTrailers(
                                    request_meta.trailers,
                                );
                            }
                        }
                    }
                },
                .duplex => |duplex| {
                    if (duplex.requestTrailers()) |fields| {
                        self.cached_trailers = self.copyTrailers(fields);
                    }
                },
                .h2_stream => |h2_stream| {
                    if (h2_stream.stream.trailers()) |fields| {
                        self.cached_trailers = self.copyTrailers(fields);
                    }
                },
                .h3_stream => |h3_stream| {
                    if (h3_stream.stream.trailers()) |fields| {
                        self.cached_trailers = self.copyTrailers(fields);
                    }
                },
                .limited => |limited| {
                    // Unwrap the per-route budget wrapper; trailers belong to
                    // the underlying transport reader.
                    self.body_reader = limited.inner;
                    return self.trailers();
                },
                else => {},
            }
        }
        if (self.cached_trailers) |cached| return cached;
        return self.request.trailers;
    }

    /// Look up a request trailer by name.
    pub fn trailer(self: *Ctx, name: []const u8) ?[]const u8 {
        for (self.trailers()) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, name)) {
                return field.value;
            }
        }
        return null;
    }

    fn copyTrailers(self: *Ctx, fields: anytype) ?[]const Header {
        const copied = self.arena.alloc(Header, fields.len) catch return null;
        for (fields, copied) |field, *destination| {
            // The source may be released by the transport after this call
            // (for example a completed HTTP/1 streaming request), so copy the
            // field bytes into the request arena.
            const name = self.arena.dupe(u8, field.name) catch return null;
            const value = self.arena.dupe(u8, field.value) catch return null;
            destination.* = .{ .name = name, .value = value };
        }
        return copied;
    }

    /// Decode any `Content-Encoding` layers using the request arena.
    ///
    /// The decoded output is bounded by `Limits.max_body_bytes`. An absent or
    /// `identity` encoding borrows the original body without allocating.
    pub fn decodedBody(self: *Ctx) ![]const u8 {
        const decoded = netz.http1.content_coding.decodeHeadersAlloc(
            self.arena,
            self.request.headers,
            try self.readBody(),
            self.limits.max_body_bytes,
        ) catch |err| switch (err) {
            error.UnsupportedContentEncoding => return error.UnsupportedMediaType,
            error.DecodedBodyTooLarge,
            error.EncodedBodyTooLarge,
            => return error.PayloadTooLarge,
            error.InvalidContentEncoding,
            error.TooManyContentEncodings,
            error.InvalidDecoderState,
            error.AliasedBuffers,
            => return error.BadRequest,
            else => return err,
        };
        return decoded.bytes;
    }

    pub fn param(self: *const Ctx, name: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    /// Look up the first decoded query value. Repeated keys resolve to the
    /// first occurrence; `queryPairs` exposes the full ordered list.
    pub fn queryParam(self: *const Ctx, name: []const u8) ?[]const u8 {
        if (self.query_params.len > 0) {
            for (self.query_params) |pair| {
                if (std.mem.eql(u8, pair.name, name)) return pair.value;
            }
            return null;
        }

        // Fallback for manually constructed contexts that only set `query`.
        var pairs = std.mem.splitScalar(u8, self.query, '&');
        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            if (std.mem.eql(u8, pair[0..equals], name)) {
                return query_mod.decodeComponent(
                    self.arena,
                    pair[equals + 1 ..],
                    true,
                ) catch null;
            }
        }
        return null;
    }

    /// All decoded query pairs in wire order.
    pub fn queryPairs(self: *const Ctx) []const QueryPair {
        return self.query_params;
    }

    /// Parse the decoded request body as JSON using the request arena.
    ///
    /// The request must declare `application/json` or a structured
    /// `+json` media type such as `application/problem+json`; otherwise
    /// `error.UnsupportedMediaType` maps to `415`.
    pub fn bodyJson(self: *Ctx, comptime T: type) !T {
        const content_type = self.header("content-type") orelse
            return error.UnsupportedMediaType;
        if (!isJsonMediaType(content_type)) {
            return error.UnsupportedMediaType;
        }
        return std.json.parseFromSliceLeaky(
            T,
            self.arena,
            try self.decodedBody(),
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
    }

    /// Parse an `application/x-www-form-urlencoded` request body. The returned
    /// query owns arena allocations for the request lifetime.
    pub fn bodyForm(self: *Ctx) !query_mod.Query {
        const media_type = "application/x-www-form-urlencoded";
        const content_type = self.header("content-type") orelse
            return error.UnsupportedMediaType;
        if (!std.ascii.startsWithIgnoreCase(content_type, media_type)) {
            return error.UnsupportedMediaType;
        }
        if (content_type.len > media_type.len) {
            const delimiter = content_type[media_type.len];
            if (delimiter != ';' and delimiter != ' ' and delimiter != '\t') {
                return error.UnsupportedMediaType;
            }
        }
        return query_mod.parse(
            self.arena,
            try self.decodedBody(),
            self.limits.max_query_params,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadRequest,
        };
    }

    /// Parse a decoded `multipart/form-data` body. Part data borrows the
    /// request body; parser-owned names and headers use the request arena.
    pub fn multipart(self: *Ctx) !multipart_mod.Form {
        const content_type = self.header("content-type") orelse
            return error.UnsupportedMediaType;
        return multipart_mod.parse(
            self.arena,
            content_type,
            try self.decodedBody(),
            .{ .max_parts = self.limits.max_multipart_parts },
        );
    }

    /// Incrementally parse a `multipart/form-data` body from the streaming
    /// reader. Requires a streaming route; the parser keeps a fixed window
    /// bounded by `Limits.max_streaming_window_bytes` and enforces
    /// `Limits.max_body_bytes` across the whole body.
    pub fn multipartStream(self: *Ctx) !multipart_stream_mod.Stream {
        const reader = self.body_reader orelse
            return error.NotStreamingRoute;
        const content_type = self.header("content-type") orelse
            return error.UnsupportedMediaType;

        // The source closure needs a stable address; keep the reader copy in
        // the request arena.
        const holder = try self.arena.create(BodyReader);
        holder.* = reader;
        return multipart_stream_mod.Stream.init(
            self.arena,
            .{ .context = holder, .next_fn = bodyReaderNext },
            content_type,
            .{
                .max_parts = self.limits.max_multipart_parts,
                .max_body_bytes = self.limits.max_body_bytes,
                // The window comes from the request arena, so keep at least
                // half of it available for headers, names, and the stream
                // state itself.
                .buffer_bytes = @min(
                    self.limits.max_streaming_window_bytes,
                    self.limits.max_request_arena_bytes / 2,
                ),
            },
        );
    }

    fn bodyReaderNext(raw: ?*anyopaque) anyerror!?[]const u8 {
        const reader: *BodyReader = @ptrCast(@alignCast(raw orelse
            return error.InvalidReaderState));
        return reader.next();
    }

    /// Read a request cookie by name. Cookie names are case-sensitive.
    pub fn cookie(self: *const Ctx, name: []const u8) ?[]const u8 {
        return cookie_mod.find(self.request.headers, name);
    }

    /// Append a `Set-Cookie` response field.
    pub fn setCookie(self: *Ctx, set_cookie: SetCookie) !void {
        try self.addHeader(
            "Set-Cookie",
            try cookie_mod.serialize(self.arena, set_cookie),
        );
    }

    pub fn set(self: *Ctx, comptime T: type, value: T) !void {
        const ptr = try self.arena.create(T);
        ptr.* = value;
        try self.locals.put(
            self.arena,
            @typeName(T),
            @ptrCast(ptr),
        );
    }

    pub fn get(self: *Ctx, comptime T: type) ?T {
        const raw = self.locals.get(@typeName(T)) orelse return null;
        const ptr: *T = @ptrCast(@alignCast(raw));
        return ptr.*;
    }

    pub fn setStatus(self: *Ctx, status: u16) void {
        self.response.setStatus(status);
    }

    pub fn setHeader(
        self: *Ctx,
        name: []const u8,
        value: []const u8,
    ) !void {
        try self.response.setHeader(name, value);
    }

    /// Append a header field, preserving duplicates. Intended for list-valued
    /// fields such as `Set-Cookie`.
    pub fn addHeader(
        self: *Ctx,
        name: []const u8,
        value: []const u8,
    ) !void {
        try self.response.appendHeader(name, value);
    }

    /// Append a trailer field emitted after the response body.
    pub fn addTrailer(
        self: *Ctx,
        name: []const u8,
        value: []const u8,
    ) !void {
        try self.response.addTrailer(name, value);
    }

    pub fn responseHeader(self: *const Ctx, name: []const u8) ?[]const u8 {
        return self.response.header(name);
    }

    pub fn text(self: *Ctx, value: []const u8) !void {
        try self.response.text(value);
    }

    pub fn redirect(self: *Ctx, status: u16, location: []const u8) !void {
        if (status < 300 or status > 399) return error.InvalidRedirectStatus;
        self.setStatus(status);
        try self.setHeader("Location", location);
    }

    pub fn json(self: *Ctx, value: anytype) !void {
        try self.response.json(value);
    }

    /// Select an incremental body producer. The producer runs after the
    /// handler returns and may write at most `Limits.max_response_bytes`.
    pub fn stream(self: *Ctx, stream_body: StreamBody) !void {
        if (self.response.stream != null) return error.StreamAlreadySet;
        if (self.response.upgrade != null) return error.UpgradeAlreadySet;
        if (self.response.body.len != 0 or self.response.body_owned) {
            return error.BodyAlreadySet;
        }
        if (stream_body.length) |length| {
            if (length > self.limits.max_response_bytes) {
                return error.ResponseTooLarge;
            }
        }
        self.response.stream = stream_body;
        self.response.committed = true;
    }

    /// Select an incremental `text/event-stream` body. Defaults `Content-Type`
    /// and `Cache-Control` only when the handler has not set them.
    pub fn sse(self: *Ctx, stream_body: StreamBody) !void {
        if (self.responseHeader("content-type") == null) {
            try self.setHeader("Content-Type", "text/event-stream");
        }
        if (self.responseHeader("cache-control") == null) {
            try self.setHeader("Cache-Control", "no-cache");
        }
        if (self.responseHeader("x-accel-buffering") == null) {
            try self.setHeader("X-Accel-Buffering", "no");
        }
        try self.stream(stream_body);
    }

    /// Select an HTTP/1 WebSocket upgrade. The HTTP/1 server validates the
    /// opening handshake, writes `101`, and runs `upgrade.run_fn` synchronously
    /// on the connection worker.
    pub fn upgradeWebSocket(self: *Ctx, upgrade: WebSocketUpgrade) !void {
        if (self.response.stream != null) return error.StreamAlreadySet;
        if (self.response.upgrade != null) return error.UpgradeAlreadySet;
        if (self.response.body.len != 0 or self.response.body_owned) {
            return error.BodyAlreadySet;
        }
        self.response.upgrade = upgrade;
        self.response.setStatus(101);
        self.response.committed = true;
    }

    pub fn notFound(self: *Ctx) !void {
        self.setStatus(404);
        try self.text("Not Found");
    }

    pub fn internalError(self: *Ctx) !void {
        self.setStatus(500);
        try self.text("Internal Server Error");
    }
};

/// Accept `application/json` and structured-suffix types such as
/// `application/problem+json`, ignoring media-type parameters.
fn isJsonMediaType(value: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media = std.mem.trim(u8, value[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(media, "application/json")) return true;
    const slash = std.mem.indexOfScalar(u8, media, '/') orelse return false;
    return std.ascii.endsWithIgnoreCase(media[slash + 1 ..], "+json");
}

/// Wrap a compile-time route handler that receives the application context.
pub fn handlerFor(
    comptime H: type,
    comptime f: fn (*H, *Ctx) anyerror!void,
) Handler {
    return .{
        .context = null,
        .call_fn = struct {
            fn call(_: ?*anyopaque, ctx: *Ctx) anyerror!void {
                const app: *H = @ptrCast(@alignCast(ctx.app));
                return f(app, ctx);
            }
        }.call,
    };
}

/// Wrap a plain middleware/handler function.
pub fn handler(comptime f: fn (*Ctx) anyerror!void) Handler {
    return .{
        .context = null,
        .call_fn = struct {
            fn call(_: ?*anyopaque, ctx: *Ctx) anyerror!void {
                return f(ctx);
            }
        }.call,
    };
}

/// Wrap a parameterized middleware/handler. `context` must outlive the router.
pub fn withContext(
    comptime T: type,
    context: *T,
    comptime f: fn (*T, *Ctx) anyerror!void,
) Handler {
    return .{
        .context = context,
        .call_fn = struct {
            fn call(raw: ?*anyopaque, ctx: *Ctx) anyerror!void {
                const typed: *T = @ptrCast(@alignCast(raw.?));
                return f(typed, ctx);
            }
        }.call,
    };
}

test "headerValues iterates duplicate request fields" {
    var headers = [_]netz.http1.Header{
        .{ .name = "X-Test", .value = "one" },
        .{ .name = "x-test", .value = "two" },
        .{ .name = "Other", .value = "three" },
    };
    var request = netz.http1.Request{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &headers,
        .body = "",
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = Response.init(arena.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    var values = context.headerValues("X-Test");
    try std.testing.expectEqualStrings("one", values.next().?);
    try std.testing.expectEqualStrings("two", values.next().?);
    try std.testing.expect(values.next() == null);
    try std.testing.expectEqual(@as(usize, 3), context.headers().len);
}

test "trailers are exposed by name and as a slice" {
    var trailers = [_]netz.http1.Header{
        .{ .name = "X-Checksum", .value = "abc" },
        .{ .name = "X-Trace", .value = "one" },
    };
    var request = netz.http1.Request{
        .method = .POST,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .trailers = &trailers,
        .consumed = 0,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .response = Response.init(arena.allocator(), 1024),
        .final_handler = handler(struct {
            fn handle(ctx: *Ctx) anyerror!void {
                _ = ctx;
            }
        }.handle),
    };

    try std.testing.expectEqual(@as(usize, 2), context.trailers().len);
    try std.testing.expectEqualStrings("abc", context.trailer("x-checksum").?);
    try std.testing.expect(context.trailer("missing") == null);
}

test "client address honors a trusted forwarded-for header" {
    const peer = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    var headers = [_]netz.http1.Header{.{
        .name = "X-Forwarded-For",
        .value = "203.0.113.7, 10.0.0.1",
    }};

    const trusted = resolveClientAddress(&headers, peer, true).?;
    const expected = try std.Io.net.IpAddress.parse("203.0.113.7", 0);
    try std.testing.expect(trusted.eql(&expected));

    const untrusted = resolveClientAddress(&headers, peer, false).?;
    try std.testing.expect(untrusted.eql(&peer));

    var invalid = [_]netz.http1.Header{.{
        .name = "X-Forwarded-For",
        .value = "not-an-ip",
    }};
    const fallback = resolveClientAddress(&invalid, peer, true).?;
    try std.testing.expect(fallback.eql(&peer));

    var quoted = [_]netz.http1.Header{.{
        .name = "X-Forwarded-For",
        .value = "\"2001:db8::1\"",
    }};
    const ipv6 = resolveClientAddress(&quoted, peer, true).?;
    const expected6 = try std.Io.net.IpAddress.parse("2001:db8::1", 0);
    try std.testing.expect(ipv6.eql(&expected6));
}

test "json media type accepts parameters and structured suffixes" {
    try std.testing.expect(isJsonMediaType("application/json"));
    try std.testing.expect(isJsonMediaType("Application/JSON; charset=utf-8"));
    try std.testing.expect(isJsonMediaType(
        "application/problem+json",
    ));
    try std.testing.expect(isJsonMediaType(
        "application/vnd.api+json; profile=\"x\"",
    ));
    try std.testing.expect(!isJsonMediaType("text/plain"));
    try std.testing.expect(!isJsonMediaType("application/jsonx"));
    try std.testing.expect(!isJsonMediaType("json"));
    try std.testing.expect(!isJsonMediaType(""));
}

test "typed locals round-trip through the request arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var locals = Locals{};
    const value = @as(u32, 42);
    const ptr = try arena.allocator().create(u32);
    ptr.* = value;
    try locals.put(arena.allocator(), @typeName(u32), @ptrCast(ptr));
    const raw = locals.get(@typeName(u32)).?;
    const typed: *u32 = @ptrCast(@alignCast(raw));
    try std.testing.expectEqual(@as(u32, 42), typed.*);
}
