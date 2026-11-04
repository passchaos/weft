//! Request-target normalization for routing.
//!
//! HTTP/1 clients and proxies may send an absolute-form target
//! (`http://example.com/path?q=1`) in addition to origin-form. Netz validates
//! the target and makes its authority authoritative for `Host`; weft still
//! needs the path and query for the router.

const std = @import("std");
const netz = @import("netz");

pub const Split = struct {
    path: []const u8,
    query: []const u8,
};

/// Split an origin-form or absolute-form request target into the path and
/// query used by the router. Absolute-form without a path maps to `/`.
pub fn split(target: []const u8) Split {
    var rest = target;
    if (netz.http1.absoluteFormAuthority(target)) |authority| {
        const scheme_end = std.mem.indexOf(u8, target, "://") orelse
            return originForm(target);
        const authority_start = scheme_end + 3;
        rest = target[authority_start + authority.len ..];
        if (rest.len == 0) return .{ .path = "/", .query = "" };
        if (rest[0] == '?') {
            return .{ .path = "/", .query = rest[1..] };
        }
        // A fragment is not valid in an HTTP request target; keep it out of
        // the query so routing still sees the path.
        if (rest[0] == '#') return .{ .path = "/", .query = "" };
    }
    return originForm(rest);
}

fn originForm(target: []const u8) Split {
    const query_index = std.mem.indexOfScalar(u8, target, '?');
    return .{
        .path = if (query_index) |index| target[0..index] else target,
        .query = if (query_index) |index| target[index + 1 ..] else "",
    };
}

test "target splitting handles origin and absolute forms" {
    const origin = split("/users/42?q=1");
    try std.testing.expectEqualStrings("/users/42", origin.path);
    try std.testing.expectEqualStrings("q=1", origin.query);

    const absolute = split("http://example.com/users/42?q=1");
    try std.testing.expectEqualStrings("/users/42", absolute.path);
    try std.testing.expectEqualStrings("q=1", absolute.query);

    const absolute_root = split("https://example.com");
    try std.testing.expectEqualStrings("/", absolute_root.path);
    try std.testing.expectEqualStrings("", absolute_root.query);

    const absolute_query = split("HTTP://example.com?q=1");
    try std.testing.expectEqualStrings("/", absolute_query.path);
    try std.testing.expectEqualStrings("q=1", absolute_query.query);

    const with_port = split("http://example.com:8080/a/b");
    try std.testing.expectEqualStrings("/a/b", with_port.path);
    try std.testing.expectEqualStrings("", with_port.query);

    const asterisk = split("*");
    try std.testing.expectEqualStrings("*", asterisk.path);
    try std.testing.expectEqualStrings("", asterisk.query);
}
