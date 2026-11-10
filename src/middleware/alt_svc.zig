const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const response_mod = @import("../response.zig");

/// Default advertisement for a server listening for HTTP/3 on port 443.
pub const default_h3 = "h3=\":443\"; ma=86400";

/// Advertise an alternative HTTP/3 endpoint on responses served over
/// HTTP/1.1 or HTTP/2. HTTP/3 responses already use the advertised protocol,
/// so the header is skipped there by default.
pub const AltSvc = struct {
    value: []const u8 = default_h3,
    skip_http3: bool = true,

    pub fn handler(self: *AltSvc) handler_mod.Handler {
        return handler_mod.withContext(AltSvc, self, call);
    }

    fn call(self: *AltSvc, ctx: *ctx_mod.Ctx) anyerror!void {
        if (!(self.skip_http3 and ctx.protocol() == .http_3)) {
            try ctx.response.setHeaderIfAbsent("Alt-Svc", self.value);
        }
        try ctx.next();
    }
};

test "alt-svc advertises h3 on http/1.1 but not on http/3" {
    const std = @import("std");
    const netz = @import("netz");

    var alt = AltSvc{};
    var request: netz.http1.Request = .{
        .method = .GET,
        .target = "/",
        .version = .http_1_1,
        .headers = &.{},
        .body = "",
        .consumed = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var http1 = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .limits = .{},
        .request = &request,
        .client_info = .{ .protocol = .http_1_1 },
        .response = response_mod.Response.init(arena.allocator(), 1024),
        .middleware = &.{alt.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };
    try http1.run();
    try std.testing.expectEqualStrings(
        default_h3,
        http1.response.header("alt-svc").?,
    );

    var h3_request = request;
    var h3_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer h3_arena.deinit();
    var http3 = ctx_mod.Ctx{
        .app = undefined,
        .io = std.testing.io,
        .arena = h3_arena.allocator(),
        .limits = .{},
        .request = &h3_request,
        .client_info = .{ .protocol = .http_3 },
        .response = response_mod.Response.init(h3_arena.allocator(), 1024),
        .middleware = &.{alt.handler()},
        .final_handler = handler_mod.handler(struct {
            fn handle(ctx: *ctx_mod.Ctx) anyerror!void {
                try ctx.text("ok");
            }
        }.handle),
    };
    try http3.run();
    try std.testing.expect(http3.response.header("alt-svc") == null);
}
