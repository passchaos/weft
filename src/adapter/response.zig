const std = @import("std");
const response_mod = @import("../response.zig");
const limits_mod = @import("../limits.zig");

pub fn internalErrorResponse(
    arena: std.mem.Allocator,
    limits: limits_mod.Limits,
) response_mod.Response {
    var response = response_mod.Response.initWithLimits(arena, limits);
    response.setStatus(500);
    response.text("Internal Server Error") catch {};
    return response;
}
