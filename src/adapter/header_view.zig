const std = @import("std");
const netz = @import("netz");
const response_mod = @import("../response.zig");

/// Maps HTTP/2 HPACK or HTTP/3 QPACK fields onto weft's HTTP/1-style header
/// view and back. The field type only needs `name` and `value` members.
pub fn HeaderView(comptime Field: type) type {
    return struct {
        pub fn convertTrailers(
            allocator: std.mem.Allocator,
            fields: []const Field,
        ) ![]netz.http1.Header {
            const headers = try allocator.alloc(netz.http1.Header, fields.len);
            for (fields, headers) |field, *header| {
                header.* = .{ .name = field.name, .value = field.value };
            }
            return headers;
        }

        pub fn convertHeadersInto(
            destination: []netz.http1.Header,
            fields: []const Field,
            authority: ?[]const u8,
        ) ?[]netz.http1.Header {
            var count: usize = 0;
            for (fields) |field| {
                if (!isPseudoHeader(field.name)) count += 1;
            }
            const add_host = authority != null and findHeader(fields, "host") == null;
            if (add_host) count += 1;
            if (count > destination.len) return null;

            var index: usize = 0;
            for (fields) |field| {
                if (isPseudoHeader(field.name)) continue;
                destination[index] = .{ .name = field.name, .value = field.value };
                index += 1;
            }
            if (add_host) {
                destination[index] = .{
                    .name = "Host",
                    .value = authority.?,
                };
            }
            return destination[0..count];
        }

        pub fn convertHeaders(
            allocator: std.mem.Allocator,
            fields: []const Field,
            authority: ?[]const u8,
        ) ![]netz.http1.Header {
            var count: usize = 0;
            for (fields) |field| {
                if (!isPseudoHeader(field.name)) count += 1;
            }
            const add_host = authority != null and findHeader(fields, "host") == null;
            if (add_host) count += 1;
            const headers = try allocator.alloc(netz.http1.Header, count);
            return convertHeadersInto(headers, fields, authority).?;
        }

        pub fn trailerFields(
            response: *const response_mod.Response,
            arena: std.mem.Allocator,
        ) ![]const Field {
            var fields = std.ArrayListUnmanaged(Field).empty;
            try fields.ensureTotalCapacity(arena, response.trailers.items.len);
            for (response.trailers.items) |header| {
                fields.appendAssumeCapacity(.{
                    .name = try lowerHeaderName(arena, header.name),
                    .value = header.value,
                });
            }
            return fields.items;
        }

        /// Lowercase and filter caller-supplied headers for an interim
        /// response head. Forbidden connection-specific fields are dropped.
        pub fn informationalFields(
            arena: std.mem.Allocator,
            headers: []const netz.http1.Header,
        ) ![]const Field {
            var fields = std.ArrayListUnmanaged(Field).empty;
            try fields.ensureTotalCapacity(arena, headers.len);
            for (headers) |header| {
                if (forbiddenResponseHeader(header.name)) continue;
                fields.appendAssumeCapacity(.{
                    .name = try lowerHeaderName(arena, header.name),
                    .value = header.value,
                });
            }
            return fields.items;
        }

        pub fn headerFields(
            response: *const response_mod.Response,
            arena: std.mem.Allocator,
        ) ![]const Field {
            var fields = std.ArrayListUnmanaged(Field).empty;
            try fields.ensureTotalCapacity(arena, response.headers.items.len);
            for (response.headers.items) |header| {
                if (forbiddenResponseHeader(header.name)) continue;
                fields.appendAssumeCapacity(.{
                    .name = try lowerHeaderName(arena, header.name),
                    .value = header.value,
                });
            }
            return fields.items;
        }

        /// HTTP/2 and HTTP/3 field names are lowercase. Response names already
        /// live in the request arena, so an already-lowercase name is borrowed
        /// instead of copied.
        pub fn lowerHeaderName(
            arena: std.mem.Allocator,
            name: []const u8,
        ) ![]const u8 {
            for (name) |char| {
                if (char >= 'A' and char <= 'Z') {
                    const copy = try arena.alloc(u8, name.len);
                    for (name, copy) |source, *target| {
                        target.* = std.ascii.toLower(source);
                    }
                    return copy;
                }
            }
            return name;
        }

        pub fn forbiddenResponseHeader(name: []const u8) bool {
            if (name.len == 0 or name[0] == ':') return true;
            inline for (.{
                "connection",
                "keep-alive",
                "proxy-connection",
                "transfer-encoding",
                "upgrade",
                "host",
                "te",
            }) |forbidden| {
                if (std.ascii.eqlIgnoreCase(name, forbidden)) return true;
            }
            return false;
        }

        pub fn isPseudoHeader(name: []const u8) bool {
            return name.len > 0 and name[0] == ':';
        }

        pub fn findHeader(
            headers: []const Field,
            name: []const u8,
        ) ?[]const u8 {
            for (headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
            }
            return null;
        }
    };
}
