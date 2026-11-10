const std = @import("std");
const vort = @import("vort");

pub fn encode(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]u8 {
    return vort.br.encodePlannedStreamChunksAlloc(
        allocator,
        &.{body},
    );
}

pub fn initEncoder(
    allocator: std.mem.Allocator,
) !vort.br.IncrementalPlannedStreamEncoder {
    return vort.br.IncrementalPlannedStreamEncoder.initWithOptions(
        allocator,
        .{},
    );
}
