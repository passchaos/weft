comptime {
    _ = @import("router_test.zig");
    _ = @import("http1_test.zig");
    _ = @import("http2_test.zig");
    _ = @import("http3_test.zig");
    _ = @import("tls_test.zig");
    _ = @import("static_test.zig");
    _ = @import("middleware_test.zig");
    _ = @import("websocket_test.zig");
    _ = @import("multipart_test.zig");
    _ = @import("openapi_mcp_test.zig");
}
