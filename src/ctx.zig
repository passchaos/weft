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
const body_mod = @import("body.zig");
const handler_mod = @import("handler.zig");

const Response = response_mod.Response;
const Header = netz.http1.Header;
const Limits = limits_mod.Limits;
const QueryPair = query_mod.Pair;
const SetCookie = cookie_mod.SetCookie;
const StreamBody = stream_mod.Body;
const StreamWriter = stream_mod.Writer;
const SseEvent = sse_mod.Event;
const ReplayReader = body_mod.ReplayReader;
const stream_reader_buffer_bytes = body_mod.stream_reader_buffer_bytes;
const H2StreamReader = body_mod.H2StreamReader;
const H3StreamReader = body_mod.H3StreamReader;
const LimitedReader = body_mod.LimitedReader;
const DecodedReader = body_mod.DecodedReader;
const BodyReader = body_mod.BodyReader;

const WebSocketSession = websocket_mod.Session;
const WebSocketUpgrade = websocket_mod.Upgrade;

const Param = handler_mod.Param;
const Protocol = handler_mod.Protocol;
const ClientInfo = handler_mod.ClientInfo;
const resolveClientAddress = handler_mod.resolveClientAddress;
const max_params = handler_mod.max_params;
const Handler = handler_mod.Handler;
const max_locals = handler_mod.max_locals;
const Locals = handler_mod.Locals;

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
    /// Cached incremental `Content-Encoding` decoder for this request.
    cached_decoded_reader: ?*DecodedReader = null,
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
    /// Route-scoped middleware, run after the application middleware and
    /// before `final_handler`. Kept separate so dispatch does not have to
    /// concatenate the two slices per request.
    route_middleware: []const Handler = &.{},
    final_handler: Handler,
    /// Adapter callback for interim 103 Early Hints responses.
    early_hints_context: ?*anyopaque = null,
    early_hints_fn: ?*const fn (?*anyopaque, []const Header) anyerror!void = null,
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

        const route_index = self.index - self.middleware.len;
        if (route_index < self.route_middleware.len) {
            const middleware_handler = self.route_middleware[route_index];
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

    /// Send an interim 103 Early Hints response before the final response.
    ///
    /// The adapter writes the head immediately. Calling this after the final
    /// response has started returns the adapter's error. Adapters without
    /// interim-response support return `error.EarlyHintsUnsupported`.
    pub fn sendEarlyHints(self: *Ctx, fields: []const Header) anyerror!void {
        const send = self.early_hints_fn orelse
            return error.EarlyHintsUnsupported;
        return send(self.early_hints_context, fields);
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
        // After `readBody` a streaming request is buffered in the arena; keep
        // `body()` coherent with the bytes the handler has already consumed.
        if (self.cached_body) |cached| return cached;
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
        // Once decoding has started, `readBody` continues the decoded stream
        // so mixing `decodedReader()` and `readBody()` stays coherent.
        const effective: BodyReader = if (self.cached_decoded_reader) |decoded|
            .{ .decoded = decoded }
        else
            reader;

        // Grow a staging buffer outside the fixed request arena: ArrayList
        // growth cannot reclaim intermediate blocks from a bump allocator,
        // which could otherwise exhaust the arena for a body that fits it.
        // The final bytes are copied into the arena exactly once.
        const staging = self.request_allocator orelse self.arena;
        var output = std.ArrayListUnmanaged(u8).empty;
        defer if (self.request_allocator != null) output.deinit(staging);
        var total: usize = 0;
        while (try effective.next()) |chunk| {
            const next_total = std.math.add(usize, total, chunk.len) catch
                return error.PayloadTooLarge;
            if (next_total > self.limits.max_body_bytes or
                next_total > self.limits.max_request_arena_bytes)
            {
                return error.PayloadTooLarge;
            }
            output.appendSlice(staging, chunk) catch
                return error.PayloadTooLarge;
            total = next_total;
        }
        const cached = if (self.request_allocator != null)
            self.arena.dupe(u8, output.items) catch
                return error.PayloadTooLarge
        else
            output.items;
        self.cached_body = cached;
        return cached;
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
    ///
    /// Budget and decoding wrappers are peeled off without replacing
    /// `body_reader`, so reading the body after inspecting trailers still goes
    /// through the route limit and the active content decoder.
    pub fn trailers(self: *Ctx) []const Header {
        if (self.cached_trailers) |cached| return cached;
        if (self.transportReader()) |reader| {
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
                else => {},
            }
        }
        if (self.cached_trailers) |cached| return cached;
        return self.request.trailers;
    }

    /// The transport reader underneath any budget/decoding wrappers. This is
    /// only a view; it does not change the reader used for body access.
    fn transportReader(self: *const Ctx) ?BodyReader {
        var reader = self.body_reader orelse return null;
        while (true) {
            reader = switch (reader) {
                .limited => |limited| limited.inner,
                .decoded => |decoded| decoded.inner,
                else => return reader,
            };
        }
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
        // `readBody` already returns decoded bytes when a streaming decoder
        // is active; decoding again would corrupt the body.
        if (self.cached_decoded_reader != null) return self.readBody();
        const staging = self.request_allocator orelse self.arena;
        var decoded = netz.http1.content_coding.decodeHeadersAlloc(
            staging,
            self.request.headers,
            try self.readBody(),
            self.limits.max_body_bytes,
        ) catch |err| switch (err) {
            // Without a server staging allocator the arena is both the body
            // and decoder budget, so exhaustion is a request-size failure.
            error.OutOfMemory => return if (self.request_allocator == null)
                error.PayloadTooLarge
            else
                error.OutOfMemory,
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
        if (self.request_allocator != null and decoded.owned != null) {
            // Decoder growth cannot reclaim intermediate blocks from the
            // fixed request arena; copy the final bytes once instead.
            const cached = self.arena.dupe(u8, decoded.bytes) catch {
                decoded.deinit(staging);
                return error.PayloadTooLarge;
            };
            decoded.deinit(staging);
            return cached;
        }
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
                return query_mod.decodeComponentBorrowed(
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
            // The fixed request arena is a request budget, not a system
            // allocation; exhaustion means the body is too large.
            error.OutOfMemory => return error.PayloadTooLarge,
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
            error.OutOfMemory => return error.PayloadTooLarge,
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
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.PayloadTooLarge,
            else => return err,
        };
    }

    /// Incremental request-body decoder for `Content-Encoding`. Returns null
    /// when the body is not encoded or the route is not streaming. Encoded and
    /// decoded bytes are both bounded by `Limits.max_body_bytes`.
    pub fn decodedReader(self: *Ctx) !?*DecodedReader {
        if (self.cached_decoded_reader) |cached| return cached;
        // Starting a decoder after the raw body was buffered would replay
        // inconsistent bytes; reject the mix explicitly.
        if (self.cached_body != null) return error.InvalidReaderState;
        const reader = self.body_reader orelse return null;
        const encoding = self.header("content-encoding") orelse return null;
        if (std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, encoding, " \t"),
            "identity",
        )) return null;

        const chain = netz.http.content_coding.parseHeaders(
            self.request.headers,
        ) catch return error.UnsupportedMediaType;
        const decoder = chain.streamDecoder(self.arena, .{
            .max_encoded_bytes = self.limits.max_body_bytes,
            .max_decoded_bytes = self.limits.max_body_bytes,
            .intermediate_buffer_bytes = @max(
                1,
                @min(self.limits.max_streaming_window_bytes, 4 * 1024),
            ),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.PayloadTooLarge,
            else => return error.UnsupportedMediaType,
        };
        const chunk = @max(
            1,
            @min(self.limits.max_streaming_window_bytes, 4 * 1024),
        );
        const output = self.arena.alloc(u8, chunk) catch
            return error.PayloadTooLarge;
        const decoded = self.arena.create(DecodedReader) catch
            return error.PayloadTooLarge;
        decoded.* = .{
            .inner = reader,
            .decoder = decoder,
            .output = output,
            .max_decoded = self.limits.max_body_bytes,
        };
        self.cached_decoded_reader = decoded;
        return decoded;
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
        // the request arena. Encoded bodies are decoded incrementally, and the
        // parse window shrinks so decoder state still fits the arena.
        const decoded = try self.decodedReader();
        const holder = self.arena.create(BodyReader) catch
            return error.PayloadTooLarge;
        if (decoded) |value| {
            holder.* = .{ .decoded = value };
        } else {
            holder.* = reader;
        }
        const window_cap = if (decoded != null)
            self.limits.max_request_arena_bytes / 4
        else
            self.limits.max_request_arena_bytes / 2;
        return multipart_stream_mod.Stream.init(
            self.arena,
            .{ .context = holder, .next_fn = bodyReaderNext },
            content_type,
            .{
                .max_parts = self.limits.max_multipart_parts,
                .max_body_bytes = self.limits.max_body_bytes,
                .buffer_bytes = @min(
                    self.limits.max_streaming_window_bytes,
                    window_cap,
                ),
            },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.PayloadTooLarge,
            else => return err,
        };
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
        // Common cookies serialize into a stack buffer; only unusually large
        // values allocate a staging copy before the response takes its own.
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        cookie_mod.write(&writer, set_cookie) catch |err| switch (err) {
            error.WriteFailed => {
                return self.addHeader(
                    "Set-Cookie",
                    try cookie_mod.serialize(self.arena, set_cookie),
                );
            },
            else => return err,
        };
        try self.addHeader("Set-Cookie", writer.buffered());
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
        try self.response.setHeaderIfAbsent(
            "Content-Type",
            "text/event-stream",
        );
        try self.response.setHeaderIfAbsent("Cache-Control", "no-cache");
        try self.response.setHeaderIfAbsent("X-Accel-Buffering", "no");
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
pub fn isJsonMediaType(value: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media = std.mem.trim(u8, value[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(media, "application/json")) return true;
    const slash = std.mem.indexOfScalar(u8, media, '/') orelse return false;
    return std.ascii.endsWithIgnoreCase(media[slash + 1 ..], "+json");
}

const handlerFor = handler_mod.handlerFor;
const handler = handler_mod.handler;
const withContext = handler_mod.withContext;
