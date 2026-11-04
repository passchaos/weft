const std = @import("std");
const netz = @import("netz");

/// Bounded resource policy for one weft server.
///
/// Every field maps either to a Netz HTTP/1 limit or to a weft-owned
/// per-request budget. The defaults are deliberately conservative; applications
/// should set `max_body_bytes`, `max_response_bytes`, and
/// `max_request_arena_bytes` to the values their routes actually need.
pub const Limits = struct {
    /// Maximum bytes accepted for one request head.
    max_head_bytes: usize = 64 * 1024,
    /// Maximum request fields accepted by the HTTP/1 connection loop.
    max_request_headers: usize = 100,
    /// Maximum request-target bytes.
    max_request_target_bytes: usize = std.math.maxInt(u16) - 1,
    /// Maximum decoded request body bytes.
    max_body_bytes: usize = 16 * 1024 * 1024,
    /// Per-request arena used for response headers, response bodies, path
    /// parameters, and middleware locals.
    max_request_arena_bytes: usize = 256 * 1024,
    /// Maximum response body bytes accepted before the response is written.
    max_response_bytes: usize = 16 * 1024 * 1024,
    /// Maximum response header fields accepted before the response is written.
    max_response_headers: usize = 100,
    /// Maximum bytes for the response status line and header fields. This
    /// bounds the response head independently of the body budget.
    max_response_head_bytes: usize = 64 * 1024,
    /// Maximum number of global plus route middleware entries for one request.
    max_middleware: usize = 32,
    /// Maximum decoded query pairs stored for one request. Repeated keys each
    /// count as one pair.
    max_query_params: usize = 64,
    /// Maximum parts accepted from one multipart/form-data body.
    max_multipart_parts: usize = 64,
    /// Bounded copy window used to stream request bodies to a handler task.
    /// The protocol layer still enforces `max_body_bytes` on the total body.
    max_streaming_window_bytes: usize = 256 * 1024,
    /// Maximum simultaneously open HTTP/2 request streams per connection.
    /// Bounds buffered DATA while a connection is processed serially.
    max_http2_concurrent_streams: ?u32 = 16,
    /// Local HTTP/2 frame payload allocation ceiling.
    max_http2_frame_payload: usize = 1024 * 1024,
    /// Optional wall-clock budget for handler and middleware execution. When
    /// set, weft races the chain against a timer and cancels it at the next
    /// cancellation point, returning `503`.
    request_timeout: ?std.Io.Duration = null,
    /// Absolute Slowloris-style request-head budget. Set to null only when a
    /// trusted transport already provides an equivalent deadline.
    request_head_timeout: ?std.Io.Duration = .fromSeconds(30),
    /// Disable Nagle for application-driven writes.
    tcp_nodelay: bool = true,
    /// Treat the leftmost `X-Forwarded-For` entry as the client address.
    /// Enable only when every request arrives through a trusted proxy that
    /// sanitizes the header; otherwise clients can spoof their address in
    /// logs, rate-limit buckets, and `Ctx.clientAddress()`.
    trust_forwarded_for: bool = false,
    /// Emit a Date field when the response does not contain one.
    auto_date_header: bool = true,
    /// Permit persistent HTTP/1 connections.
    keep_alive: bool = true,
    /// Complete-message write shape used by Netz.
    write_strategy: netz.http1.runtime.WriteStrategy = .auto,

    pub fn toNetz(self: Limits) netz.http1.runtime.Limits {
        return .{
            .max_head_bytes = self.max_head_bytes,
            .max_request_headers = self.max_request_headers,
            .max_request_target_bytes = self.max_request_target_bytes,
            .max_body_bytes = self.max_body_bytes,
            .request_head_timeout = self.request_head_timeout,
            .tcp_nodelay = self.tcp_nodelay,
            .auto_date_header = self.auto_date_header,
            .keep_alive = self.keep_alive,
            .write_strategy = self.write_strategy,
        };
    }

    pub fn toHttp2Netz(self: Limits) netz.http2.runtime.Limits {
        return .{
            .max_body_bytes = self.max_body_bytes,
            .max_header_fields = self.max_request_headers,
            .max_header_list_size = self.max_head_bytes,
            .handshake_timeout = self.request_head_timeout,
            .auto_date_header = self.auto_date_header,
            .tcp_nodelay = self.tcp_nodelay,
            .max_concurrent_streams = self.max_http2_concurrent_streams,
            .max_frame_payload = self.max_http2_frame_payload,
        };
    }

    pub fn toHttp3Netz(self: Limits) netz.http3.runtime.Limits {
        return .{
            .max_stream_buffer = std.math.add(
                usize,
                self.max_body_bytes,
                self.max_head_bytes,
            ) catch std.math.maxInt(usize),
            .auto_date_header = self.auto_date_header,
        };
    }
};
