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
    /// Absolute Slowloris-style request-head budget.
    request_head_timeout: ?std.Io.Duration = null,
    /// Disable Nagle for application-driven writes.
    tcp_nodelay: bool = true,
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
};
