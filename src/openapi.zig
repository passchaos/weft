//! OpenAPI 3.1 document generation from registered routes.
//!
//! Route metadata is attached with `RouteOptions.openapi`. The router projects
//! its registered routes into `RouteView` values (`Router.openapiRoutes`), and
//! `Document.init` renders a deterministic OpenAPI 3.1 JSON document.
//! `Document.handler` serves the document; `Document.uiHandler` serves a small
//! Swagger UI page when `Options.ui` is configured.
//!
//! The module never touches protocol framing. It borrows route patterns and
//! operation metadata, copies everything into the document, and keeps only the
//! rendered bytes.

const std = @import("std");
const ctx_mod = @import("ctx.zig");

pub const Handler = ctx_mod.Handler;

/// JSON Schema subset used by parameters, request bodies, and responses.
/// Set `raw_json` to provide a complete schema object instead; it is parsed
/// and validated when the document is built.
pub const Schema = struct {
    /// JSON Schema type: `object`, `array`, `string`, `integer`, `number`,
    /// `boolean`, or null for a free-form schema.
    type: ?[]const u8 = null,
    format: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Object properties. Ignored unless `type` is `object`.
    properties: []const Property = &.{},
    /// Required property names for object schemas.
    required: []const []const u8 = &.{},
    /// Element schema for `array`.
    items: ?*const Schema = null,
    /// Allowed string values.
    enum_values: []const []const u8 = &.{},
    /// Raw JSON value copied into `example`.
    example_json: ?[]const u8 = null,
    /// Raw JSON value copied into `default`.
    default_json: ?[]const u8 = null,
    /// Emit `[type, "null"]` for the type.
    nullable: bool = false,
    /// Emit `additionalProperties: false` when false.
    additional_properties: bool = true,
    /// Complete JSON schema object. Replaces the generated object.
    raw_json: ?[]const u8 = null,
};

pub const Property = struct {
    name: []const u8,
    schema: Schema = .{},
};

pub const ParameterLocation = enum {
    query,
    header,
    path,
    cookie,

    fn jsonName(self: ParameterLocation) []const u8 {
        return @tagName(self);
    }
};

pub const Parameter = struct {
    name: []const u8,
    location: ParameterLocation = .query,
    description: ?[]const u8 = null,
    /// Path parameters are always required regardless of this value.
    required: ?bool = null,
    schema: Schema = .{ .type = "string" },
    example_json: ?[]const u8 = null,
};

pub const RequestBody = struct {
    description: ?[]const u8 = null,
    required: bool = false,
    content_type: []const u8 = "application/json",
    schema: Schema = .{ .type = "object" },
};

pub const Response = struct {
    status: u16 = 200,
    description: []const u8 = "OK",
    /// Null means the response has no body.
    content_type: ?[]const u8 = null,
    schema: ?Schema = null,
    /// Response header names to descriptions.
    headers: []const HeaderDescription = &.{},
};

pub const HeaderDescription = struct {
    name: []const u8,
    description: []const u8,
};

pub const Operation = struct {
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    deprecated: bool = false,
    /// Explicit parameters. Path captures are generated automatically; an
    /// explicit `path` parameter with the same name replaces the generated
    /// schema.
    parameters: []const Parameter = &.{},
    request_body: ?RequestBody = null,
    /// Responses keyed by status. Empty means `200 OK` without a body.
    responses: []const Response = &.{},
    /// Security requirement scheme names (each with no scopes).
    security: []const []const u8 = &.{},
    /// Keep the route out of the document.
    hidden: bool = false,
};

/// One registered route as seen by the document builder. `method` is the
/// uppercase method name; null means the route matches every method.
pub const RouteView = struct {
    method: ?[]const u8,
    pattern: []const u8,
    operation: ?Operation = null,
};

pub const Contact = struct {
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const License = struct {
    name: []const u8,
    identifier: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const Info = struct {
    title: []const u8,
    version: []const u8 = "0.1.0",
    description: ?[]const u8 = null,
    terms_of_service: ?[]const u8 = null,
    contact: ?Contact = null,
    license: ?License = null,
};

pub const Server = struct {
    url: []const u8,
    description: ?[]const u8 = null,
};

pub const Tag = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const SecuritySchemeKind = enum {
    http,
    api_key,
    open_id_connect,
    oauth2,
    mutual_tls,
};

pub const SecurityScheme = struct {
    name: []const u8,
    kind: SecuritySchemeKind = .http,
    description: ?[]const u8 = null,
    /// HTTP authentication scheme: `bearer` or `basic`.
    scheme: ?[]const u8 = null,
    bearer_format: ?[]const u8 = null,
    /// API-key location: `header`, `query`, or `cookie`.
    location: ?[]const u8 = null,
    parameter_name: ?[]const u8 = null,
    /// OpenID Connect discovery URL.
    open_id_connect_url: ?[]const u8 = null,
    /// Complete JSON scheme object. Replaces the generated object.
    raw_json: ?[]const u8 = null,
};

pub const UiOptions = struct {
    title: ?[]const u8 = null,
    /// URL the browser uses to fetch the generated document.
    json_url: []const u8 = "/openapi.json",
    swagger_css_url: []const u8 = "https://unpkg.com/swagger-ui-dist@5/swagger-ui.css",
    swagger_js_url: []const u8 = "https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js",
};

pub const Options = struct {
    info: Info,
    servers: []const Server = &.{},
    tags: []const Tag = &.{},
    security_schemes: []const SecurityScheme = &.{},
    /// Raw JSON array for the document-level `security` field.
    security_json: ?[]const u8 = null,
    /// Include routes whose operation is marked `hidden`.
    include_hidden: bool = false,
    /// Methods emitted for `router.any` routes. Explicit routes on the same
    /// path take precedence.
    any_methods: []const []const u8 = &.{
        "get",
        "post",
        "put",
        "patch",
        "delete",
    },
    /// Build a Swagger UI page served by `uiHandler`.
    ui: ?UiOptions = null,
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    json: []const u8,
    html: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        routes: []const RouteView,
        options: Options,
    ) !Document {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const root = try buildDocument(arena, routes, options);
        const json = try std.json.Stringify.valueAlloc(allocator, root, .{});
        errdefer allocator.free(json);

        var html: ?[]const u8 = null;
        errdefer if (html) |bytes| allocator.free(bytes);
        if (options.ui) |ui| {
            html = try buildUi(allocator, ui, options.info.title);
        }

        return .{
            .allocator = allocator,
            .json = json,
            .html = html,
        };
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.json);
        if (self.html) |html| self.allocator.free(html);
        self.* = undefined;
    }

    /// Serve the rendered OpenAPI JSON document.
    pub fn handler(self: *Document) Handler {
        return ctx_mod.withContext(Document, self, serveJson);
    }

    /// Serve the Swagger UI page built from `Options.ui`.
    pub fn uiHandler(self: *Document) Handler {
        return ctx_mod.withContext(Document, self, serveUi);
    }

    pub fn jsonBytes(self: *const Document) []const u8 {
        return self.json;
    }

    fn serveJson(self: *Document, ctx: *ctx_mod.Ctx) anyerror!void {
        try ctx.setHeader("Content-Type", "application/json");
        try ctx.text(self.json);
    }

    fn serveUi(self: *Document, ctx: *ctx_mod.Ctx) anyerror!void {
        const html = self.html orelse return error.UiNotConfigured;
        try ctx.setHeader("Content-Type", "text/html; charset=utf-8");
        try ctx.text(html);
    }
};

fn buildDocument(
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

fn buildUi(
    allocator: std.mem.Allocator,
    ui: UiOptions,
    document_title: []const u8,
) ![]const u8 {
    const title = ui.title orelse document_title;
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try output.appendSlice("<!doctype html>\n<html lang=\"en\">\n<head>\n");
    try output.appendSlice("<meta charset=\"utf-8\">\n");
    try output.appendSlice("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try appendHtmlEscaped(&output, title);
    try output.appendSlice("</title>\n<link rel=\"stylesheet\" href=\"");
    try appendHtmlEscaped(&output, ui.swagger_css_url);
    try output.appendSlice("\">\n</head>\n<body>\n<div id=\"swagger-ui\"></div>\n<script src=\"");
    try appendHtmlEscaped(&output, ui.swagger_js_url);
    try output.appendSlice("\"></script>\n<script>SwaggerUIBundle({url: \"");
    try appendHtmlEscaped(&output, ui.json_url);
    try output.appendSlice("\", dom_id: \"#swagger-ui\"});</script>\n</body>\n</html>\n");
    return output.toOwnedSlice();
}

fn appendHtmlEscaped(output: *std.array_list.Managed(u8), bytes: []const u8) !void {
    for (bytes) |byte| {
        switch (byte) {
            '&' => try output.appendSlice("&amp;"),
            '<' => try output.appendSlice("&lt;"),
            '>' => try output.appendSlice("&gt;"),
            '"' => try output.appendSlice("&quot;"),
            '\'' => try output.appendSlice("&#39;"),
            else => try output.append(byte),
        }
    }
}

test "openapi builds paths, captures, and operations" {
    const allocator = std.testing.allocator;

    const item_schema = Schema{
        .type = "object",
        .properties = &.{
            .{ .name = "id", .schema = .{ .type = "integer" } },
            .{ .name = "name", .schema = .{ .type = "string" } },
        },
        .required = &.{"id"},
    };

    const routes = [_]RouteView{
        .{
            .method = "GET",
            .pattern = "/hello/:name",
            .operation = .{
                .summary = "Greet a caller",
                .operation_id = "greet",
                .tags = &.{"greeting"},
                .parameters = &.{
                    .{
                        .name = "lang",
                        .location = .query,
                        .schema = .{ .type = "string" },
                    },
                },
                .responses = &.{
                    .{
                        .status = 200,
                        .description = "Greeting",
                        .content_type = "application/json",
                        .schema = item_schema,
                    },
                },
            },
        },
        .{
            .method = "POST",
            .pattern = "/items",
            .operation = .{
                .request_body = .{ .required = true },
                .responses = &.{
                    .{ .status = 201, .description = "Created" },
                },
            },
        },
        .{
            .method = "GET",
            .pattern = "/assets/*",
        },
    };

    var document = try Document.init(allocator, &routes, .{
        .info = .{ .title = "weft test", .version = "1.2.3" },
        .security_schemes = &.{
            .{ .name = "bearer", .kind = .http, .scheme = "bearer" },
        },
    });
    defer document.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        document.jsonBytes(),
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings(
        "3.1.0",
        root.get("openapi").?.string,
    );
    try std.testing.expectEqualStrings(
        "weft test",
        root.get("info").?.object.get("title").?.string,
    );

    const paths = root.get("paths").?.object;
    const hello = paths.get("/hello/{name}").?.object.get("get").?.object;
    try std.testing.expectEqualStrings(
        "greet",
        hello.get("operationId").?.string,
    );
    const parameters = hello.get("parameters").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), parameters.len);
    try std.testing.expectEqualStrings(
        "name",
        parameters[0].object.get("name").?.string,
    );
    try std.testing.expectEqualStrings(
        "path",
        parameters[0].object.get("in").?.string,
    );
    try std.testing.expect(
        parameters[0].object.get("required").?.bool,
    );
    try std.testing.expectEqualStrings(
        "lang",
        parameters[1].object.get("name").?.string,
    );

    const items = paths.get("/items").?.object.get("post").?.object;
    try std.testing.expect(
        items.get("requestBody").?.object.get("required").?.bool,
    );
    try std.testing.expect(
        items.get("responses").?.object.get("201") != null,
    );

    const assets = paths.get("/assets/{path}").?.object.get("get").?.object;
    try std.testing.expectEqualStrings(
        "path",
        assets.get("parameters").?.array.items[0].object.get("name").?.string,
    );

    const schemes = root.get("components").?.object
        .get("securitySchemes").?.object;
    try std.testing.expectEqualStrings(
        "http",
        schemes.get("bearer").?.object.get("type").?.string,
    );
}

test "openapi expands any routes without shadowing explicit methods" {
    const allocator = std.testing.allocator;

    const routes = [_]RouteView{
        .{ .method = "GET", .pattern = "/resource" },
        .{ .method = null, .pattern = "/resource" },
    };

    var document = try Document.init(allocator, &routes, .{
        .info = .{ .title = "any" },
        .any_methods = &.{ "get", "post" },
    });
    defer document.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        document.jsonBytes(),
        .{},
    );
    defer parsed.deinit();
    const item = parsed.value.object.get("paths").?.object
        .get("/resource").?.object;
    try std.testing.expect(item.get("get") != null);
    try std.testing.expect(item.get("post") != null);
}

test "openapi rejects invalid raw schema JSON" {
    const allocator = std.testing.allocator;

    const routes = [_]RouteView{
        .{
            .method = "GET",
            .pattern = "/broken",
            .operation = .{
                .responses = &.{
                    .{
                        .status = 200,
                        .description = "Broken",
                        .content_type = "application/json",
                        .schema = .{ .raw_json = "{not json" },
                    },
                },
            },
        },
    };

    try std.testing.expectError(
        error.InvalidJsonMetadata,
        Document.init(allocator, &routes, .{ .info = .{ .title = "bad" } }),
    );
}

test "openapi builds a swagger ui page when configured" {
    const allocator = std.testing.allocator;

    const routes = [_]RouteView{
        .{ .method = "GET", .pattern = "/" },
    };

    var document = try Document.init(allocator, &routes, .{
        .info = .{ .title = "UI <test>" },
        .ui = .{ .json_url = "/openapi.json" },
    });
    defer document.deinit();

    const html = document.html.?;
    try std.testing.expect(
        std.mem.indexOf(u8, html, "UI &lt;test&gt;") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, html, "/openapi.json") != null,
    );
}
