const std = @import("std");

/// A writer passed to a streaming body producer. The concrete transport is
/// owned by the server adapter; application code only sees this bounded seam.
pub const Writer = struct {
    context: ?*anyopaque,
    write_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    pub fn write(self: *const Writer, data: []const u8) anyerror!void {
        return self.write_fn(self.context, data);
    }
};

/// A body produced incrementally after the handler returns.
///
/// `length` enables fixed-length framing when known. When it is null the
/// transport uses chunked framing and the server still enforces
/// `Limits.max_response_bytes` on the number of bytes written.
///
/// `cancel_fn` is invoked if the response is discarded before the producer
/// starts (for example a handler error or a HEAD request). A producer that has
/// started owns its resources and must release them itself, including on
/// error.
pub const Body = struct {
    context: ?*anyopaque = null,
    write_fn: *const fn (?*anyopaque, *Writer) anyerror!void,
    length: ?usize = null,
    cancel_fn: ?*const fn (?*anyopaque) void = null,

    pub fn run(self: *const Body, writer: *Writer) anyerror!void {
        return self.write_fn(self.context, writer);
    }

    pub fn cancel(self: *const Body) void {
        if (self.cancel_fn) |cancel_fn| cancel_fn(self.context);
    }
};
