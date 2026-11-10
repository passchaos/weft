const std = @import("std");
const types_mod = @import("types.zig");

const Schema = types_mod.Schema;
const Property = types_mod.Property;
const ParameterLocation = types_mod.ParameterLocation;
const Parameter = types_mod.Parameter;
const RequestBody = types_mod.RequestBody;
const Response = types_mod.Response;
const HeaderDescription = types_mod.HeaderDescription;
const Operation = types_mod.Operation;
const RouteView = types_mod.RouteView;
const Contact = types_mod.Contact;
const License = types_mod.License;
const Info = types_mod.Info;
const Server = types_mod.Server;
const Tag = types_mod.Tag;
const SecuritySchemeKind = types_mod.SecuritySchemeKind;
const SecurityScheme = types_mod.SecurityScheme;
const Options = types_mod.Options;

pub fn buildDocument(
    arena: std.mem.Allocator,
    routes: []const RouteView,
    options: Options,
) !std.json.Value {
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "openapi", stringValue("3.1.0"));
    try root.put(arena, "info", try infoValue(arena, options.info));

    if (options.servers.len != 0) {
        var servers = std.json.Array.init(arena);
        for (options.servers) |server| {
            var value: std.json.ObjectMap = .empty;
            try value.put(arena, "url", stringValue(server.url));
            if (server.description) |description| {
                try value.put(arena, "description", stringValue(description));
            }
            try servers.append(.{ .object = value });
        }
        try root.put(arena, "servers", .{ .array = servers });
    }

    if (options.tags.len != 0) {
        var tags = std.json.Array.init(arena);
        for (options.tags) |tag| {
            var value: std.json.ObjectMap = .empty;
            try value.put(arena, "name", stringValue(tag.name));
            if (tag.description) |description| {
                try value.put(arena, "description", stringValue(description));
            }
            try tags.append(.{ .object = value });
        }
        try root.put(arena, "tags", .{ .array = tags });
    }

    try root.put(arena, "paths", try pathsValue(arena, routes, options));

    if (options.security_schemes.len != 0) {
        var schemes: std.json.ObjectMap = .empty;
        for (options.security_schemes) |scheme| {
            try schemes.put(arena, scheme.name, try securitySchemeValue(arena, scheme));
        }
        var components: std.json.ObjectMap = .empty;
        try components.put(arena, "securitySchemes", .{ .object = schemes });
        try root.put(arena, "components", .{ .object = components });
    }

    if (options.security_json) |raw| {
        try root.put(arena, "security", try parseRaw(arena, raw));
    }

    return .{ .object = root };
}

fn infoValue(arena: std.mem.Allocator, info: Info) !std.json.Value {
    var value: std.json.ObjectMap = .empty;
    try value.put(arena, "title", stringValue(info.title));
    try value.put(arena, "version", stringValue(info.version));
    if (info.description) |description| {
        try value.put(arena, "description", stringValue(description));
    }
    if (info.terms_of_service) |terms| {
        try value.put(arena, "termsOfService", stringValue(terms));
    }
    if (info.contact) |contact| {
        var contact_value: std.json.ObjectMap = .empty;
        if (contact.name) |name| {
            try contact_value.put(arena, "name", stringValue(name));
        }
        if (contact.url) |url| {
            try contact_value.put(arena, "url", stringValue(url));
        }
        if (contact.email) |email| {
            try contact_value.put(arena, "email", stringValue(email));
        }
        try value.put(arena, "contact", .{ .object = contact_value });
    }
    if (info.license) |license| {
        var license_value: std.json.ObjectMap = .empty;
        try license_value.put(arena, "name", stringValue(license.name));
        if (license.identifier) |identifier| {
            try license_value.put(arena, "identifier", stringValue(identifier));
        }
        if (license.url) |url| {
            try license_value.put(arena, "url", stringValue(url));
        }
        try value.put(arena, "license", .{ .object = license_value });
    }
    return .{ .object = value };
}

const PathEntry = struct {
    template: []const u8,
    captures: []const Capture,
    methods: std.json.ObjectMap,
};

const Capture = struct {
    name: []const u8,
    wildcard: bool,
};

fn pathsValue(
    arena: std.mem.Allocator,
    routes: []const RouteView,
    options: Options,
) !std.json.Value {
    var entries = std.StringArrayHashMapUnmanaged(*PathEntry){};
    // Explicit methods first so an `any` route cannot shadow them.
    for (routes) |route| {
        if (route.method == null) continue;
        if (route.operation) |operation| {
            if (operation.hidden and !options.include_hidden) continue;
        }
        const entry = try pathEntry(arena, &entries, route.pattern);
        const method = try lowerMethod(arena, route.method.?);
        if (entry.methods.contains(method)) continue;
        try entry.methods.put(
            arena,
            method,
            try operationValue(arena, entry.captures, route.operation),
        );
    }
    for (routes) |route| {
        if (route.method != null) continue;
        if (route.operation) |operation| {
            if (operation.hidden and !options.include_hidden) continue;
        }
        const entry = try pathEntry(arena, &entries, route.pattern);
        for (options.any_methods) |method| {
            if (entry.methods.contains(method)) continue;
            try entry.methods.put(
                arena,
                method,
                try operationValue(arena, entry.captures, route.operation),
            );
        }
    }

    var paths: std.json.ObjectMap = .empty;
    for (entries.values()) |entry| {
        try paths.put(arena, entry.template, .{ .object = entry.methods });
    }
    return .{ .object = paths };
}

fn pathEntry(
    arena: std.mem.Allocator,
    entries: *std.StringArrayHashMapUnmanaged(*PathEntry),
    pattern: []const u8,
) !*PathEntry {
    const converted = try convertPattern(arena, pattern);
    if (entries.get(converted.template)) |existing| return existing;
    const entry = try arena.create(PathEntry);
    entry.* = .{
        .template = converted.template,
        .captures = converted.captures,
        .methods = .empty,
    };
    try entries.put(arena, converted.template, entry);
    return entry;
}

const ConvertedPattern = struct {
    template: []const u8,
    captures: []const Capture,
};

fn convertPattern(arena: std.mem.Allocator, pattern: []const u8) !ConvertedPattern {
    var template = std.array_list.Managed(u8).init(arena);
    var captures = std.array_list.Managed(Capture).init(arena);
    var capture_names = std.StringHashMapUnmanaged(void){};

    var segments = std.mem.splitScalar(
        u8,
        std.mem.trimEnd(u8, pattern, "/"),
        '/',
    );
    var first = true;
    while (segments.next()) |segment| {
        if (first) {
            first = false;
            if (segment.len == 0) continue;
        }
        try template.append('/');
        if (segment.len != 0 and segment[0] == ':') {
            const name = segment[1..];
            try capture_names.put(arena, name, {});
            try captures.append(.{ .name = name, .wildcard = false });
            try template.append('{');
            try template.appendSlice(name);
            try template.append('}');
        } else if (std.mem.eql(u8, segment, "*")) {
            var name: []const u8 = "path";
            var suffix: usize = 2;
            while (capture_names.contains(name)) : (suffix += 1) {
                name = try std.fmt.allocPrint(arena, "path{d}", .{suffix});
            }
            try capture_names.put(arena, name, {});
            try captures.append(.{ .name = name, .wildcard = true });
            try template.append('{');
            try template.appendSlice(name);
            try template.append('}');
        } else {
            try template.appendSlice(segment);
        }
    }
    if (template.items.len == 0) try template.append('/');
    return .{
        .template = try template.toOwnedSlice(),
        .captures = try captures.toOwnedSlice(),
    };
}

fn operationValue(
    arena: std.mem.Allocator,
    captures: []const Capture,
    operation: ?Operation,
) !std.json.Value {
    const op = operation orelse Operation{};
    var value: std.json.ObjectMap = .empty;
    if (op.summary) |summary| {
        try value.put(arena, "summary", stringValue(summary));
    }
    if (op.description) |description| {
        try value.put(arena, "description", stringValue(description));
    }
    if (op.operation_id) |id| {
        try value.put(arena, "operationId", stringValue(id));
    }
    if (op.tags.len != 0) {
        var tags = std.json.Array.init(arena);
        for (op.tags) |tag| try tags.append(stringValue(tag));
        try value.put(arena, "tags", .{ .array = tags });
    }
    if (op.deprecated) try value.put(arena, "deprecated", .{ .bool = true });

    var parameters = std.json.Array.init(arena);
    var explicit_path_names = std.StringHashMapUnmanaged(void){};
    for (op.parameters) |parameter| {
        if (parameter.location != .path) continue;
        try explicit_path_names.put(arena, parameter.name, {});
    }
    for (captures) |capture| {
        if (explicit_path_names.contains(capture.name)) continue;
        try parameters.append(try parameterValue(arena, .{
            .name = capture.name,
            .location = .path,
            .required = true,
            .description = if (capture.wildcard)
                "Remaining request path"
            else
                null,
        }));
    }
    for (op.parameters) |parameter| {
        try parameters.append(try parameterValue(arena, parameter));
    }
    if (parameters.items.len != 0) {
        try value.put(arena, "parameters", .{ .array = parameters });
    }

    if (op.request_body) |body| {
        try value.put(arena, "requestBody", try requestBodyValue(arena, body));
    }

    try value.put(arena, "responses", try responsesValue(arena, op.responses));

    if (op.security.len != 0) {
        var security = std.json.Array.init(arena);
        for (op.security) |scheme| {
            var requirement: std.json.ObjectMap = .empty;
            try requirement.put(
                arena,
                scheme,
                .{ .array = std.json.Array.init(arena) },
            );
            try security.append(.{ .object = requirement });
        }
        try value.put(arena, "security", .{ .array = security });
    }

    return .{ .object = value };
}

fn parameterValue(arena: std.mem.Allocator, parameter: Parameter) !std.json.Value {
    var value: std.json.ObjectMap = .empty;
    try value.put(arena, "name", stringValue(parameter.name));
    try value.put(arena, "in", stringValue(parameter.location.jsonName()));
    if (parameter.description) |description| {
        try value.put(arena, "description", stringValue(description));
    }
    const required = parameter.required orelse
        (parameter.location == .path);
    if (required) try value.put(arena, "required", .{ .bool = true });
    try value.put(arena, "schema", try schemaValue(arena, parameter.schema));
    if (parameter.example_json) |raw| {
        try value.put(arena, "example", try parseRaw(arena, raw));
    }
    return .{ .object = value };
}

fn requestBodyValue(arena: std.mem.Allocator, body: RequestBody) !std.json.Value {
    var value: std.json.ObjectMap = .empty;
    if (body.description) |description| {
        try value.put(arena, "description", stringValue(description));
    }
    if (body.required) try value.put(arena, "required", .{ .bool = true });
    var content: std.json.ObjectMap = .empty;
    var media: std.json.ObjectMap = .empty;
    try media.put(arena, "schema", try schemaValue(arena, body.schema));
    try content.put(arena, body.content_type, .{ .object = media });
    try value.put(arena, "content", .{ .object = content });
    return .{ .object = value };
}

fn responsesValue(
    arena: std.mem.Allocator,
    responses: []const Response,
) !std.json.Value {
    var value: std.json.ObjectMap = .empty;
    if (responses.len == 0) {
        var ok: std.json.ObjectMap = .empty;
        try ok.put(arena, "description", stringValue("OK"));
        try value.put(arena, "200", .{ .object = ok });
        return .{ .object = value };
    }
    for (responses) |response| {
        var item: std.json.ObjectMap = .empty;
        try item.put(arena, "description", stringValue(response.description));
        if (response.content_type) |content_type| {
            var content: std.json.ObjectMap = .empty;
            var media: std.json.ObjectMap = .empty;
            if (response.schema) |schema| {
                try media.put(arena, "schema", try schemaValue(arena, schema));
            }
            try content.put(arena, content_type, .{ .object = media });
            try item.put(arena, "content", .{ .object = content });
        }
        if (response.headers.len != 0) {
            var headers: std.json.ObjectMap = .empty;
            for (response.headers) |header| {
                var header_value: std.json.ObjectMap = .empty;
                try header_value.put(
                    arena,
                    "description",
                    stringValue(header.description),
                );
                try headers.put(arena, header.name, .{ .object = header_value });
            }
            try item.put(arena, "headers", .{ .object = headers });
        }
        const key = try std.fmt.allocPrint(arena, "{d}", .{response.status});
        try value.put(arena, key, .{ .object = item });
    }
    return .{ .object = value };
}

fn schemaValue(arena: std.mem.Allocator, schema: Schema) !std.json.Value {
    if (schema.raw_json) |raw| return parseRaw(arena, raw);

    var value: std.json.ObjectMap = .empty;
    if (schema.type) |schema_type| {
        if (schema.nullable) {
            var types = std.json.Array.init(arena);
            try types.append(stringValue(schema_type));
            try types.append(stringValue("null"));
            try value.put(arena, "type", .{ .array = types });
        } else {
            try value.put(arena, "type", stringValue(schema_type));
        }
    }
    if (schema.format) |format| {
        try value.put(arena, "format", stringValue(format));
    }
    if (schema.description) |description| {
        try value.put(arena, "description", stringValue(description));
    }
    if (schema.properties.len != 0) {
        var properties: std.json.ObjectMap = .empty;
        for (schema.properties) |property| {
            try properties.put(
                arena,
                property.name,
                try schemaValue(arena, property.schema),
            );
        }
        try value.put(arena, "properties", .{ .object = properties });
    }
    if (schema.required.len != 0) {
        var required = std.json.Array.init(arena);
        for (schema.required) |name| try required.append(stringValue(name));
        try value.put(arena, "required", .{ .array = required });
    }
    if (schema.items) |items| {
        try value.put(arena, "items", try schemaValue(arena, items.*));
    }
    if (schema.enum_values.len != 0) {
        var enum_values = std.json.Array.init(arena);
        for (schema.enum_values) |item| {
            try enum_values.append(stringValue(item));
        }
        try value.put(arena, "enum", .{ .array = enum_values });
    }
    if (schema.example_json) |raw| {
        try value.put(arena, "example", try parseRaw(arena, raw));
    }
    if (schema.default_json) |raw| {
        try value.put(arena, "default", try parseRaw(arena, raw));
    }
    if (!schema.additional_properties) {
        try value.put(arena, "additionalProperties", .{ .bool = false });
    }
    return .{ .object = value };
}

fn securitySchemeValue(
    arena: std.mem.Allocator,
    scheme: SecurityScheme,
) !std.json.Value {
    if (scheme.raw_json) |raw| return parseRaw(arena, raw);

    var value: std.json.ObjectMap = .empty;
    const type_name: []const u8 = switch (scheme.kind) {
        .http => "http",
        .api_key => "apiKey",
        .open_id_connect => "openIdConnect",
        .oauth2 => "oauth2",
        .mutual_tls => "mutualTLS",
    };
    try value.put(arena, "type", stringValue(type_name));
    if (scheme.description) |description| {
        try value.put(arena, "description", stringValue(description));
    }
    switch (scheme.kind) {
        .http => {
            if (scheme.scheme) |http_scheme| {
                try value.put(arena, "scheme", stringValue(http_scheme));
            }
            if (scheme.bearer_format) |format| {
                try value.put(arena, "bearerFormat", stringValue(format));
            }
        },
        .api_key => {
            if (scheme.location) |location| {
                try value.put(arena, "in", stringValue(location));
            }
            if (scheme.parameter_name) |name| {
                try value.put(arena, "name", stringValue(name));
            }
        },
        .open_id_connect => {
            if (scheme.open_id_connect_url) |url| {
                try value.put(
                    arena,
                    "openIdConnectUrl",
                    stringValue(url),
                );
            }
        },
        .oauth2 => {},
        .mutual_tls => {},
    }
    return .{ .object = value };
}

fn stringValue(bytes: []const u8) std.json.Value {
    return .{ .string = bytes };
}

fn parseRaw(arena: std.mem.Allocator, raw: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        raw,
        .{},
    ) catch return error.InvalidJsonMetadata;
}

fn lowerMethod(arena: std.mem.Allocator, method: []const u8) ![]const u8 {
    const lower = try arena.alloc(u8, method.len);
    for (method, 0..) |char, index| {
        lower[index] = std.ascii.toLower(char);
    }
    return lower;
}
