const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const handler_mod = @import("../handler.zig");
const vary = @import("../vary.zig");
const negotiator = @import("compress/negotiate.zig");
const gzip = @import("compress/gzip.zig");
const deflate = @import("compress/deflate.zig");
const brotli = @import("compress/brotli.zig");
const zstd = @import("compress/zstd.zig");
const continuous = @import("compress/continuous.zig");

const flate = std.compress.flate;

/// Response compression with bounded, content-type-aware negotiation.
///
/// The middleware negotiates gzip, deflate, Brotli, and zstd from
/// `Accept-Encoding` quality values. It compresses only responses that already
/// have a complete body and are larger than `min_bytes`, and never compresses a
/// response that already selected a `Content-Encoding` or asked for
/// `no-transform`.
pub const Compress = struct {
    min_bytes: usize = 1024,
    level: flate.Compress.Options = .default,
    enable_gzip: bool = true,
    enable_deflate: bool = true,
    enable_br: bool = true,
    enable_zstd: bool = true,
    zstd_level: c_int = 3,

    pub fn handler(self: *Compress) handler_mod.Handler {
        return handler_mod.withContext(Compress, self, call);
    }

    fn call(self: *Compress, ctx: *ctx_mod.Ctx) anyerror!void {
        const negotiation = self.negotiate(ctx);
        try ctx.next();

        const response = &ctx.response;
        if (response.hasHeader("content-encoding")) return;
        if (negotiator.noTransform(response.header("cache-control"))) return;

        if (response.stream) |body| {
            const coding = switch (negotiation) {
                .coding => |value| value,
                .identity => {
                    // `Vary` is only needed when another Accept-Encoding
                    // would select a different representation.
                    if (!negotiator.compressible(response.header("content-type"))) return;
                    if (body.length) |length| {
                        if (length < self.min_bytes) return;
                    }
                    try vary.add(ctx, "Accept-Encoding");
                    return;
                },
                .not_acceptable => {
                    // Identity was explicitly refused and no coding is
                    // acceptable. A stream cannot be negotiated after the
                    // producer has been selected, so replace it with 406.
                    body.cancel();
                    response.stream = null;
                    response.reset();
                    response.setStatus(406);
                    response.text("Not Acceptable") catch {};
                    try vary.add(ctx, "Accept-Encoding");
                    return;
                },
            };
            if (!negotiator.compressible(response.header("content-type"))) return;
            if (body.length) |length| {
                if (length < self.min_bytes) return;
            }
            try vary.add(ctx, "Accept-Encoding");
            switch (coding) {
                .gzip => {
                    const wrapped = gzip.wrap(
                        ctx.arena,
                        body,
                        self.level,
                        ctx.limits.max_response_bytes,
                    ) catch return;
                    response.setHeader("Content-Encoding", "gzip") catch return;
                    _ = response.removeHeader("content-length");
                    response.stream = wrapped;
                },
                .deflate, .br, .zstd => {
                    const wrapped = continuous.wrap(
                        ctx.arena,
                        body,
                        coding,
                    ) catch return;
                    response.setHeader(
                        "Content-Encoding",
                        coding.headerValue(),
                    ) catch return;
                    _ = response.removeHeader("content-length");
                    response.stream = wrapped;
                },
            }
            return;
        }

        switch (negotiation) {
            .identity => {
                // See the streaming identity case above.
                if (response.body.len < self.min_bytes) return;
                if (!negotiator.compressible(response.header("content-type"))) return;
                try vary.add(ctx, "Accept-Encoding");
                return;
            },
            .not_acceptable => {
                response.reset();
                response.setStatus(406);
                response.text("Not Acceptable") catch {};
                try vary.add(ctx, "Accept-Encoding");
                return;
            },
            .coding => |coding| {
                if (response.body.len < self.min_bytes) return;
                if (!negotiator.compressible(response.header("content-type"))) return;
                try vary.add(ctx, "Accept-Encoding");

                // Compress in the server allocator and copy the final bytes
                // into the arena once, so encoder growth cannot exhaust the
                // fixed request arena for a body that fits.
                const staging = ctx.request_allocator orelse ctx.arena;
                const compressed = compressBody(
                    staging,
                    response.body,
                    coding,
                    self.level,
                    self.zstd_level,
                ) catch return;
                const body = if (ctx.request_allocator != null)
                    ctx.arena.dupe(u8, compressed) catch {
                        staging.free(compressed);
                        return;
                    }
                else
                    compressed;
                if (ctx.request_allocator != null) staging.free(compressed);
                response.setHeader(
                    "Content-Encoding",
                    coding.headerValue(),
                ) catch {
                    ctx.arena.free(body);
                    return;
                };
                response.setBody(body) catch {
                    _ = response.removeHeader("content-encoding");
                    ctx.arena.free(body);
                    return;
                };
            },
        }
    }

    fn negotiate(
        self: *const Compress,
        ctx: *const ctx_mod.Ctx,
    ) negotiator.Negotiation {
        const header = ctx.header("accept-encoding") orelse return .identity;

        var gzip_quality: ?u16 = null;
        var deflate_quality: ?u16 = null;
        var br_quality: ?u16 = null;
        var zstd_quality: ?u16 = null;
        var identity_quality: ?u16 = null;
        var wildcard_quality: ?u16 = null;
        var saw_known = false;

        var parts = std.mem.splitScalar(u8, header, ',');
        while (parts.next()) |part| {
            const item = std.mem.trim(u8, part, " \t");
            if (item.len == 0) continue;
            const semicolon = std.mem.indexOfScalar(u8, item, ';');
            const coding = std.mem.trim(
                u8,
                if (semicolon) |index| item[0..index] else item,
                " \t",
            );
            const q = if (semicolon) |index|
                negotiator.quality(item[index + 1 ..]) orelse 1000
            else
                1000;

            if (std.ascii.eqlIgnoreCase(coding, "gzip") or
                std.ascii.eqlIgnoreCase(coding, "x-gzip"))
            {
                gzip_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "deflate")) {
                deflate_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "br")) {
                br_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "zstd")) {
                zstd_quality = q;
            } else if (std.ascii.eqlIgnoreCase(coding, "identity")) {
                identity_quality = q;
            } else if (std.mem.eql(u8, coding, "*")) {
                wildcard_quality = q;
            } else {
                continue;
            }
            saw_known = true;
        }

        if (!saw_known) return .identity;

        const wildcard = wildcard_quality orelse 0;
        const gzip_q = if (self.enable_gzip)
            gzip_quality orelse wildcard
        else
            0;
        const deflate_q = if (self.enable_deflate)
            deflate_quality orelse wildcard
        else
            0;
        const br_q = if (self.enable_br)
            br_quality orelse wildcard
        else
            0;
        const zstd_q = if (self.enable_zstd)
            zstd_quality orelse wildcard
        else
            0;
        const identity_q = identity_quality orelse
            (if (wildcard_quality != null and wildcard == 0)
                @as(u16, 0)
            else
                @as(u16, 1000));

        var best: ?negotiator.Coding = null;
        var best_quality: u16 = 0;
        if (br_q > 0 and br_q > best_quality) {
            best = .br;
            best_quality = br_q;
        }
        if (zstd_q > 0 and zstd_q > best_quality) {
            best = .zstd;
            best_quality = zstd_q;
        }
        if (gzip_q > 0 and gzip_q > best_quality) {
            best = .gzip;
            best_quality = gzip_q;
        }
        if (deflate_q > 0 and deflate_q > best_quality) {
            best = .deflate;
            best_quality = deflate_q;
        }
        if (best) |coding| return .{ .coding = coding };
        if (identity_q > 0) return .identity;
        return .not_acceptable;
    }
};

/// Apply default gzip/deflate/Brotli/zstd negotiation.
pub fn compress(ctx: *ctx_mod.Ctx) anyerror!void {
    var defaults = Compress{};
    return defaults.call(ctx);
}

fn compressBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    coding: negotiator.Coding,
    level: flate.Compress.Options,
    zstd_level: c_int,
) ![]const u8 {
    return switch (coding) {
        .gzip => gzip.encode(allocator, body, level),
        .deflate => deflate.encode(allocator, body, level),
        .br => brotli.encode(allocator, body),
        .zstd => zstd.encode(allocator, body, zstd_level),
    };
}
