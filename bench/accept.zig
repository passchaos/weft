//! `Accept` negotiation benchmark.
//!
//! Measures `accept.preferred` with a realistic browser header and three
//! candidates. Parsing is allocation-free; the benchmark isolates the scan and
//! quality-parsing cost.

const std = @import("std");
const weft = @import("weft");

const iterations: usize = 1_000_000;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const candidates = [_][]const u8{
        "application/json",
        "text/html",
        "image/webp",
    };
    const header = "text/html, application/xhtml+xml, application/xml;q=0.9, " ++
        "image/webp;q=0.8, */*;q=0.1";

    var checksum: usize = 0;
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        const chosen = weft.accept.preferred(header, &candidates) orelse "";
        checksum +%= chosen.len;
        if (weft.accept.accepts(header, "application/json")) checksum +%= 1;
    }
    const elapsed = start.untilNow(io, .awake);
    std.mem.doNotOptimizeAway(checksum);

    const elapsed_ns = @as(f64, @floatFromInt(elapsed.nanoseconds));
    const count = @as(f64, @floatFromInt(iterations));
    std.debug.print(
        "accept: iterations={d} {d:.1} ns/negotiation {d:.0} negotiations/s\n",
        .{
            iterations,
            elapsed_ns / count,
            count / (elapsed_ns / std.time.ns_per_s),
        },
    );
}
