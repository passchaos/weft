const ctx_mod = @import("../ctx.zig");

pub const default_value = "weft";

pub fn serverHeader(ctx: *ctx_mod.Ctx) anyerror!void {
    try ctx.response.setHeaderIfAbsent("Server", default_value);
    try ctx.next();
}
